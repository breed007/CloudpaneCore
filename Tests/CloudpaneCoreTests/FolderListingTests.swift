import Darwin
import XCTest
@testable import CloudpaneCore

/// Thread-safe notes taken on the walk thread.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _listings: [(path: String, policy: Int32)] = []
    private var _reads: [(path: String, policy: Int32)] = []
    private var _listed: Set<String> = []

    func listing(_ path: String, _ policy: Int32) { lock.withLock { _listings.append((path, policy)); _listed.insert(path) } }
    func read(_ path: String, _ policy: Int32) { lock.withLock { _reads.append((path, policy)) } }
    var listings: [(path: String, policy: Int32)] { lock.withLock { _listings } }
    var reads: [(path: String, policy: Int32)] { lock.withLock { _reads } }
    func wasListed(_ path: String) -> Bool { lock.withLock { _listed.contains(path) } }
}

/// The folder-listing rule: materialization is on for the walk thread only inside each
/// folder listing call and off for every per-item read. A real provider is not needed: the
/// lister's closures stand in for one.
final class FolderListingTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws { tree = try FixtureTree() }
    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    /// A lister that records the thread's policy inside each listing call, and optionally
    /// fails some folders or reports some as dataless.
    private func lister(_ recorder: Recorder, failing: Set<String> = [],
                        dataless: @escaping @Sendable (String, Bool) -> Bool = { _, _ in false }) -> FolderLister {
        var lister = FolderLister.live
        lister.list = { folder in
            recorder.listing(folder.path, MaterializationPolicy.currentThreadPolicy)
            if failing.contains(folder.path) { throw POSIXError(.EDEADLK) }
            return try FolderLister.live.list(folder)
        }
        lister.isDataless = { path in dataless(path, recorder.wasListed(path)) }
        return lister
    }

    private func scan(_ hooks: ScannerHooks, home: String? = nil) async throws -> (Inventory, Int64, EventCollector) {
        let report = ProviderCatalog(home: URL(fileURLWithPath: home ?? tree.home)).detect()
        let scanner = Scanner(roots: report.scanRoots(backups: [ScanRoot.backup(URL(fileURLWithPath: tree.backup))]),
                              placeholderRule: .default, hooks: hooks)
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        let collector = EventCollector()
        let id = try await store.recordScan(scanner, homePath: report.homePath) { collector.add($0) }
        return (store, id, collector)
    }

    func testPolicyIsOnOnlyInsideTheListingCall() async throws {
        let recorder = Recorder()
        var hooks = ScannerHooks()
        hooks.lister = lister(recorder)
        hooks.beforeItemRead = { recorder.read($0, MaterializationPolicy.currentThreadPolicy) }
        let (_, _, collector) = try await scan(hooks)

        XCTAssertGreaterThan(recorder.listings.count, 10)
        XCTAssertGreaterThan(recorder.reads.count, 30)
        for listing in recorder.listings {
            XCTAssertEqual(listing.policy, IOPOL_MATERIALIZE_DATALESS_FILES_ON, "listing \(listing.path)")
        }
        for read in recorder.reads {
            XCTAssertEqual(read.policy, IOPOL_MATERIALIZE_DATALESS_FILES_OFF, "read \(read.path)")
        }
        // Package contents are listed and read under the same rule.
        XCTAssertTrue(recorder.listings.contains { $0.path.hasSuffix("/Tool.app/Contents") })
        XCTAssertTrue(recorder.reads.contains { $0.path.hasSuffix("/Tool.app/Contents/Info.plist") })
        XCTAssertEqual(collector.summary?.materializationDisabled, true)
    }

    func testAListingFailureIsReportedAndTheWalkContinues() async throws {
        let failing = canonicalPath(tree.path(FixtureTree.oneDrivePersonal + "/Pictures"))
        let recorder = Recorder()
        var hooks = ScannerHooks()
        hooks.lister = lister(recorder, failing: [failing])
        let (store, id, collector) = try await scan(hooks)

        let issue = try XCTUnwrap(collector.issues.first { $0.path == failing })
        XCTAssertTrue(issue.message.hasPrefix("Could not list this OneDrive folder: "), issue.message)
        XCTAssertTrue(issue.message.contains("errno 11"), issue.message)
        XCTAssertTrue(issue.message.hasSuffix("Files in it are missing from this scan."), issue.message)

        let roots = try await store.rootSummaries(snapshotID: id)
        let personal = try XCTUnwrap(roots.first { $0.root.id == "onedrive/OneDrive-Personal" })
        XCTAssertEqual(personal.unlistedFolders, 1, "read back from the inventory")
        XCTAssertEqual(personal.files, 3, "Documents is still walked")
        let records = try await store.search(snapshotID: id, text: "cv.docx", in: .name, limit: 5)
        XCTAssertEqual(records.count, 1)

        // The failure makes the account a partial view, with a sentence naming the provider.
        let catalog = ProviderCatalog(home: URL(fileURLWithPath: tree.home),
                                      partialViewDetector: ScanPartialViewDetector(lastScan: roots)).detect()
        let oneDrive = try XCTUnwrap(catalog.providers.first { $0.rule.id == "onedrive" })
        let root = try XCTUnwrap(oneDrive.roots.first { $0.folderName == "OneDrive-Personal" })
        XCTAssertEqual(root.state, .partial)
        XCTAssertEqual(root.reason, "1 folder could not be listed, so the last scan is missing the files in it",
                       "an injected EDEADLK is not blamed on the provider")
        XCTAssertEqual(catalog.providers.first { $0.rule.id == "dropbox" }?.state, .installed)
    }

    func testADatalessFolderIsListedAndItsFilesRecorded() async throws {
        let cloudOnly = canonicalPath(tree.path(FixtureTree.googleDrive + "/My Drive/Projects"))
        let recorder = Recorder()
        var hooks = ScannerHooks()
        // Dataless until its listing call, as when a provider fetches the list.
        hooks.lister = lister(recorder, dataless: { path, listed in path == cloudOnly && !listed })
        let (store, id, collector) = try await scan(hooks)

        XCTAssertTrue(recorder.wasListed(cloudOnly))
        XCTAssertTrue(collector.issues.allSatisfy { $0.path != cloudOnly }, "\(collector.issues)")
        let found = try await store.search(snapshotID: id, text: "plan.docx", in: .name, limit: 5)
        XCTAssertEqual(found.count, 1)
        let deeper = try await store.search(snapshotID: id, text: "archive.zip", in: .name, limit: 5)
        XCTAssertEqual(deeper.count, 1)
        let waiting = collector.progress.filter(\.gettingFolderList)
        XCTAssertEqual(waiting.count, 1, "one progress update while the provider fetches the list")
        XCTAssertEqual(waiting.first?.currentRoot?.provider, "google-drive")
        XCTAssertEqual(collector.progress.last?.gettingFolderList, false)
        let roots = try await store.rootSummaries(snapshotID: id)
        XCTAssertEqual(roots.first { $0.root.provider == "google-drive" }?.unlistedFolders, 0)
    }

    func testAFolderStillDatalessAfterListingIsReported() async throws {
        let cloudOnly = canonicalPath(tree.path(FixtureTree.googleDrive + "/My Drive/Projects"))
        let recorder = Recorder()
        var hooks = ScannerHooks()
        hooks.lister = lister(recorder, dataless: { path, _ in path == cloudOnly })
        let (store, id, collector) = try await scan(hooks)

        let issue = try XCTUnwrap(collector.issues.first { $0.path == cloudOnly })
        XCTAssertEqual(issue.message, "Google Drive did not provide this folder's list, so files in it are missing from this scan.")
        let roots = try await store.rootSummaries(snapshotID: id)
        XCTAssertEqual(roots.first { $0.root.provider == "google-drive" }?.unlistedFolders, 1)
        XCTAssertEqual(roots.first { $0.root.provider == "google-drive" }?.unlistedNotProvided, 1)
        let catalog = ProviderCatalog(home: URL(fileURLWithPath: tree.home),
                                      partialViewDetector: ScanPartialViewDetector(lastScan: roots)).detect()
        XCTAssertEqual(catalog.providers.first { $0.rule.id == "google-drive" }?.roots.first?.reason,
                       "Google Drive did not provide the list of 1 folder on this Mac, so the last scan is missing the files in it")
    }

    /// The fixture's mode-000 OneDrive folder is a permission problem, not the provider's.
    func testAPermissionFailureIsNotBlamedOnTheProvider() async throws {
        try tree.real(10, FixtureTree.dropbox + "/Tool.app/Contents/Resources/locked/a.bin")
        try tree.lock(FixtureTree.dropbox + "/Tool.app/Contents/Resources/locked")
        let (store, id, _) = try await scan(ScannerHooks())
        let roots = try await store.rootSummaries(snapshotID: id)
        let contoso = try XCTUnwrap(roots.first { $0.root.id == "onedrive/OneDrive-Contoso" })
        XCTAssertEqual(contoso.unlistedFolders, 1)
        XCTAssertEqual(contoso.unlistedPermission, 1)
        // A folder inside a package that cannot be listed counts too.
        let dropbox = try XCTUnwrap(roots.first { $0.root.provider == "dropbox" })
        XCTAssertEqual(dropbox.unlistedPermission, 1)

        let catalog = ProviderCatalog(home: URL(fileURLWithPath: tree.home),
                                      partialViewDetector: ScanPartialViewDetector(lastScan: roots)).detect()
        let root = try XCTUnwrap(catalog.providers.first { $0.rule.id == "onedrive" }?.roots
            .first { $0.folderName == "OneDrive-Contoso" })
        XCTAssertEqual(root.state, .partial)
        XCTAssertEqual(root.reason, "1 folder could not be read because permission was denied, so the last scan is missing the files in it")
        XCTAssertEqual(catalog.providers.first { $0.rule.id == "dropbox" }?.state, .partial)
    }

    func testAPathTooLongIsNamedAsSuch() {
        var summary = RootSummary(root: ScanRoot.backup(URL(fileURLWithPath: "/tmp")))
        summary.countUnlisted(.pathTooLong)
        summary.countUnlisted(.notProvided)
        summary.countUnlisted(.other)
        let reason = ScanPartialViewDetector(lastScan: [summary])
            .partialViewReason(rule: .box, rootPath: "/tmp")
        XCTAssertEqual(reason, "Box did not provide the list of 1 folder on this Mac; 1 folder has a path too long to read; 1 folder could not be listed, so the last scan is missing the files in them")
    }

    func testAPolicyThatCannotBeTurnedBackOffStopsTheScan() async throws {
        let recorder = Recorder()
        var hooks = ScannerHooks()
        var broken = lister(recorder)
        // Pretend: turning it on works, turning it back off fails. Nothing real changes.
        broken.setPolicy = { $0 == IOPOL_MATERIALIZE_DATALESS_FILES_ON }
        hooks.lister = broken
        hooks.beforeItemRead = { recorder.read($0, 0) }
        let (_, _, collector) = try await scan(hooks)

        XCTAssertEqual(recorder.listings.count, 1, "nothing is listed after the failure")
        XCTAssertTrue(recorder.reads.isEmpty, "nothing is read after the failure")
        XCTAssertEqual(collector.summary?.wasCanceled, true)
        XCTAssertTrue(collector.issues.first?.message.hasPrefix("The scan stopped: dataless materialization could not be turned back off") == true,
                      "\(collector.issues)")
    }

    func testIncrementalRescansUseTheSameRuleAndKeepUnlistableFolders() async throws {
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let pictures = canonicalPath(tree.path(FixtureTree.oneDrivePersonal + "/Pictures"))
        let recorder = Recorder()
        var hooks = ScannerHooks()
        hooks.lister = lister(recorder)
        hooks.beforeItemRead = { recorder.read($0, MaterializationPolicy.currentThreadPolicy) }
        let ok = await IncrementalScanner(roots: report.scanRoots(), changedPaths: [pictures], rootParents: [],
                                          placeholderRule: .default, hooks: hooks).run(snapshotID: 1)
        XCTAssertEqual(ok.scope.map(\.path), [pictures])
        XCTAssertEqual(ok.records.count, 5)
        XCTAssertEqual(recorder.listings.map(\.policy), [IOPOL_MATERIALIZE_DATALESS_FILES_ON])
        XCTAssertTrue(recorder.reads.allSatisfy { $0.policy == IOPOL_MATERIALIZE_DATALESS_FILES_OFF })

        hooks.lister = lister(Recorder(), failing: [pictures])
        let failed = await IncrementalScanner(roots: report.scanRoots(), changedPaths: [pictures], rootParents: [],
                                              placeholderRule: .default, hooks: hooks).run(snapshotID: 1)
        XCTAssertTrue(failed.scope.isEmpty, "rows below a folder that could not be listed are not closed")
        XCTAssertTrue(failed.records.isEmpty)
        XCTAssertEqual(failed.issues.map(\.path), [pictures])
    }

    func testTheRealListerRestoresTheThreadPolicy() throws {
        // On a thread with materialization off, a listing leaves it off afterwards.
        let done = expectation(description: "thread")
        let outcome = Recorder()
        let folder = URL(fileURLWithPath: tree.path(FixtureTree.dropbox))
        let thread = Thread {
            MaterializationPolicy.disableForCurrentThread()
            let children = (try? FolderLister.live.contents(of: folder, includeHidden: false)) ?? []
            outcome.read("after", MaterializationPolicy.currentThreadPolicy)
            outcome.listing("children \(children.count)", 0)
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome.reads.first?.policy, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertNotEqual(outcome.listings.first?.path, "children 0")
    }
}
