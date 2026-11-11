import Darwin
import XCTest
@testable import CloudpaneCore

final class ScannerTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws {
        tree = try FixtureTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private struct Expected {
        let files: Int
        let packages: Int
        let directories: Int
        let logical: Int64
        let placeholders: Int
        let placeholderBytes: Int64
        var zeroByte = 0
        var hardLinks = 0
        var symlinks = 0
        var other = 0
        var errors = 0
        var packageLogical: Int64 = 0
    }

    private let expected: [String: Expected] = [
        "icloud-drive/com~apple~CloudDocs": Expected(
            files: 3, packages: 1, directories: 1, logical: 1000 + 2_000_000 + 12_298,
            placeholders: 1, placeholderBytes: 2_000_000, packageLogical: 12_298),
        "dropbox/Dropbox": Expected(
            files: 4, packages: 1, directories: 2, logical: 8192 + 3_000_000 + 0 + 4296,
            placeholders: 1, placeholderBytes: 3_000_000, zeroByte: 1, hardLinks: 1, symlinks: 2,
            other: 1, packageLogical: 4296),
        "google-drive/GoogleDrive-test.user@example.com": Expected(
            files: 4, packages: 0, directories: 5, logical: 12_288 + 1_500_000 + 10_000_000 + 4096,
            placeholders: 2, placeholderBytes: 11_500_000),
        "onedrive/OneDrive-Personal": Expected(
            files: 8, packages: 0, directories: 2,
            logical: 20_000 + 10 + 7 + 750_000 + 1000 + 5 + 3 + 3,
            placeholders: 2, placeholderBytes: 751_000),
        "onedrive/OneDrive-Contoso": Expected(
            files: 2, packages: 0, directories: 2, logical: 5_000_300,
            placeholders: 1, placeholderBytes: 5_000_000, errors: 1),
        "box/Box-Box": Expected(
            files: 2, packages: 0, directories: 1, logical: 2_540_960,
            placeholders: 1, placeholderBytes: 2_500_000),
        "unrecognized/ProtonDrive-test": Expected(
            files: 1, packages: 0, directories: 0, logical: 4096, placeholders: 0, placeholderBytes: 0),
    ]

    func testRootTotalsMatchTheFixture() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let summaries = try await run.inventory.rootSummaries(snapshotID: run.snapshotID)
        XCTAssertEqual(Set(summaries.map(\.root.id)), Set(expected.keys))

        for summary in summaries {
            let id = summary.root.id
            guard let want = expected[id] else { continue }
            XCTAssertEqual(summary.files, want.files, "files \(id)")
            XCTAssertEqual(summary.packages, want.packages, "packages \(id)")
            XCTAssertEqual(summary.directories, want.directories, "directories \(id)")
            XCTAssertEqual(summary.logicalBytes, want.logical, "logical \(id)")
            XCTAssertEqual(summary.placeholders, want.placeholders, "placeholders \(id)")
            XCTAssertEqual(summary.placeholderBytes, want.placeholderBytes, "placeholder bytes \(id)")
            XCTAssertEqual(summary.zeroByte, want.zeroByte, "zero-byte \(id)")
            XCTAssertEqual(summary.hardLinksSkipped, want.hardLinks, "hard links \(id)")
            XCTAssertEqual(summary.symlinksSkipped, want.symlinks, "symlinks \(id)")
            XCTAssertEqual(summary.otherTypesSkipped, want.other, "other types \(id)")
            XCTAssertEqual(summary.errors, want.errors, "errors \(id)")
            XCTAssertEqual(summary.packageLogicalBytes, want.packageLogical, "package bytes \(id)")
            XCTAssertEqual(summary.dataless, 0, "sparse files never carry SF_DATALESS")
            XCTAssertFalse(summary.wasInterrupted)
            XCTAssertGreaterThan(summary.elapsedMilliseconds, 0, "walk time \(id)")
        }

        // The files table agrees with the scanner's own counts.
        let providers = try await run.inventory.providerTotals(snapshotID: run.snapshotID)
        let oneDrive = try XCTUnwrap(providers.first { $0.provider == "onedrive" })
        XCTAssertEqual(oneDrive.providerName, "OneDrive")
        XCTAssertEqual(oneDrive.roots, 2)
        XCTAssertEqual(oneDrive.files, 10)
        XCTAssertEqual(oneDrive.logicalBytes, 771_028 + 5_000_300)
        XCTAssertEqual(oneDrive.placeholders, 3)
        XCTAssertEqual(oneDrive.placeholderBytes, 5_751_000)
        XCTAssertEqual(providers.first?.provider, "google-drive", "largest first")
        XCTAssertEqual(providers.reduce(0) { $0 + $1.files }, expected.values.reduce(0) { $0 + $1.files })

        let snapshot = try await run.inventory.snapshot(run.snapshotID)
        XCTAssertEqual(snapshot?.status, .complete)
        XCTAssertEqual(snapshot?.placeholderRule, "dataless-or-strict-v1")
        XCTAssertNotNil(snapshot?.finishedAt)
        XCTAssertEqual(run.summary?.materializationDisabled, true)
    }

    func testAllocatedSizesSeparateSparseFromReal() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let pdfs = try await run.inventory.search(snapshotID: run.snapshotID, text: ".pdf")
        let byName = Dictionary(uniqueKeysWithValues: pdfs.map { ($0.name, $0) })
        XCTAssertEqual(byName["report.pdf"]?.allocatedSize, 0)
        XCTAssertEqual(byName["msa.pdf"]?.allocatedSize, 0)
        XCTAssertGreaterThanOrEqual(byName["nda.pdf"]?.allocatedSize ?? 0, 40_960)
        XCTAssertEqual(byName["report.pdf"]?.isPlaceholder, true)
        XCTAssertEqual(byName["nda.pdf"]?.isPlaceholder, false)
        XCTAssertEqual(byName["report.pdf"]?.downloadStatus, DownloadStatus.none)
        XCTAssertEqual(byName["report.pdf"]?.isUbiquitous, false)
    }

    func testPackagesAreLeavesSizedByTheirContents() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let records = try await run.inventory.search(snapshotID: run.snapshotID, text: "photoslibrary", in: .path)
        XCTAssertEqual(records.count, 1, "nothing inside the package is a record")
        let library = try XCTUnwrap(records.first)
        XCTAssertTrue(library.isPackage)
        // Photos.sqlite + IMG_0001.heic + the hidden .lock; the symbolic link adds nothing.
        XCTAssertEqual(library.logicalSize, 8192 + 4096 + 10)
        XCTAssertGreaterThan(library.allocatedSize ?? 0, 0)
        XCTAssertFalse(library.isPlaceholder)
        XCTAssertEqual(library.relativePath, "Archive.photoslibrary")
        XCTAssertEqual(library.topLevelFolder, "")

        let app = try await run.inventory.search(snapshotID: run.snapshotID, text: "Tool.app")
        XCTAssertEqual(app.map(\.logicalSize), [4296])
        XCTAssertEqual(app.first?.category, .application)
    }

    func testSkippedItemsNeverBecomeRecords() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let paths = try await run.inventory.allPaths(snapshotID: run.snapshotID)
        let names = Set(paths.map { ($0 as NSString).lastPathComponent })
        for skipped in [".hidden-config", "flagged.txt", "cached.bin", "big.bin", "link-to-file",
                        "link-to-outside", "pipe.fifo", "a.txt", "secret.txt", "Photos.sqlite",
                        "stray-file.txt", ".DS_Store"] {
            XCTAssertFalse(names.contains(skipped), skipped)
        }
        let beach = paths.filter { $0.contains("/Photos/beach") }
        XCTAssertEqual(beach.count, 1, "a hard link pair is one record")
        XCTAssertFalse(paths.contains { !$0.hasPrefix(tree.home + "/") }, "nothing outside the home")
    }

    func testTopLevelFoldersFollowTheProviderDepth() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let folders = try await run.inventory.folderTotals(snapshotID: run.snapshotID, provider: "google-drive")
        XCTAssertEqual(folders.map(\.folder), ["My Drive", "My Drive/Projects", "Shared drives/Team"])
        XCTAssertEqual(folders.map(\.files), [1, 2, 1])
        XCTAssertEqual(folders.map(\.logicalBytes), [12_288, 11_500_000, 4096])
        XCTAssertEqual(folders.map(\.placeholders), [0, 2, 0])

        let dropbox = try await run.inventory.folderTotals(snapshotID: run.snapshotID, provider: "dropbox")
        XCTAssertEqual(dropbox.map(\.folder), ["", "Photos"])
        XCTAssertEqual(dropbox.map(\.files), [2, 2])

        let all = try await run.inventory.folderTotals(snapshotID: run.snapshotID)
        XCTAssertEqual(all.reduce(0) { $0 + $1.files }, 24)
    }

    func testTypeBreakdown() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let categories = try await run.inventory.typeBreakdown(snapshotID: run.snapshotID)
        let byKey = Dictionary(uniqueKeysWithValues: categories.map { ($0.key, $0) })
        XCTAssertEqual(categories.reduce(0) { $0 + $1.files }, 24)
        XCTAssertEqual(byKey["archive"]?.files, 1)
        XCTAssertEqual(byKey["archive"]?.logicalBytes, 10_000_000)
        // file.bin: the system says MacBinary archive; Cloudpane records generic data.
        let bin = try await run.inventory.search(snapshotID: run.snapshotID, text: "file.bin")
        XCTAssertEqual(bin.first?.contentType, "public.data")
        XCTAssertEqual(bin.first?.category, .other)
        XCTAssertEqual(byKey["application"]?.files, 1)
        XCTAssertEqual(byKey["image"]?.files, 5, "beach, day1, pic, a|b, =cmd")
        XCTAssertEqual(categories.map(\.logicalBytes), categories.map(\.logicalBytes).sorted(by: >),
                       "largest first")

        let types = try await run.inventory.typeBreakdown(snapshotID: run.snapshotID, grouping: .contentType)
        XCTAssertEqual(types.first { $0.key == "com.adobe.pdf" }?.files, 4)
    }

    func testBackupRootIsScannedAsItsOwnLocation() async throws {
        let run = try await ScanRun.run(home: tree.home, backups: [tree.backup])
        let summaries = try await run.inventory.rootSummaries(snapshotID: run.snapshotID)
        let backup = try XCTUnwrap(summaries.last)
        XCTAssertEqual(backup.root.kind, .backup)
        XCTAssertEqual(backup.root.provider, "backup")
        XCTAssertEqual(backup.files, 1)
        XCTAssertEqual(backup.logicalBytes, 1000)
        let totals = try await run.inventory.providerTotals(snapshotID: run.snapshotID)
        XCTAssertEqual(totals.first { $0.provider == "backup" }?.providerName, "Backup")
    }

    func testABackupRootContainingProviderRootsDoesNotCountThemTwice() async throws {
        let library = tree.path("Library")
        let run = try await ScanRun.run(home: tree.home, backups: [library])
        let summaries = try await run.inventory.rootSummaries(snapshotID: run.snapshotID)
        let backup = try XCTUnwrap(summaries.first { $0.root.kind == .backup })
        // Under Library: the other iCloud container's a.txt and the stray file. The provider
        // roots and the unrecognized root are walked once, under their own identity.
        XCTAssertEqual(backup.files, 2)
        XCTAssertEqual(backup.nestedRootsSkipped, 7)
        let total = try await run.inventory.providerTotals(snapshotID: run.snapshotID)
        XCTAssertEqual(total.reduce(0) { $0 + $1.files }, 24 + 2)
    }

    func testABackupRootInsideAProviderRootIsRefusedAndTotalsDoNotMove() async throws {
        let baseline = try await ScanRun.run(home: tree.home)
        let before = try await baseline.inventory.rootSummaries(snapshotID: baseline.snapshotID)

        let photos = tree.path(FixtureTree.dropbox + "/Photos")
        let dropboxRoot = tree.path(FixtureTree.dropbox)
        let run = try await ScanRun.run(home: tree.home, backups: [photos, dropboxRoot])
        let after = try await run.inventory.rootSummaries(snapshotID: run.snapshotID)
        XCTAssertFalse(after.contains { $0.root.kind == .backup })
        XCTAssertEqual(after.map(\.logicalBytes), before.map(\.logicalBytes))
        XCTAssertEqual(after.map(\.placeholders), before.map(\.placeholders))
        XCTAssertEqual(after.first { $0.root.provider == "dropbox" }?.logicalBytes, 3_012_488)

        // The scanner refuses it too when handed the roots directly, in any order.
        let synced = run.report.scanRoots()
        let sneaky = ScanRoot.backup(URL(fileURLWithPath: photos))
        let scanner = Scanner(roots: [sneaky] + synced)
        XCTAssertEqual(scanner.rejectedBackups.map(\.path), [photos])
        XCTAssertEqual(scanner.roots.map(\.id), synced.map(\.id))

        // Backups go after synced roots, so a shared hard link stays with the provider.
        let backup = ScanRoot.backup(URL(fileURLWithPath: tree.backup))
        XCTAssertEqual(Scanner(roots: [backup] + synced).roots.last?.id, backup.id)
    }

    func testUnreadableFolderIsLoggedWithErrnoAndTheWalkContinues() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let issue = try XCTUnwrap(run.issues.first { $0.rootID == "onedrive/OneDrive-Contoso" })
        XCTAssertTrue(issue.path.hasSuffix("/Shared/locked"), issue.path)
        XCTAssertTrue(issue.message.contains("errno 13 Permission denied"), issue.message)
        XCTAssertEqual(run.issues.count, 1)
    }

    func testPathLongerThanPathMaxIsReported() async throws {
        let deep = try FixtureTree(empty: true)
        defer { deep.remove() }
        let root = deep.path(FixtureTree.cloudStorage + "/Box-Box")
        try deep.folder(FixtureTree.box)
        // Build below PATH_MAX one component at a time with mkdirat, as mkdir -p cannot.
        var fd = open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        for level in 1...14 {
            let name = "level_\(level)_" + String(repeating: "x", count: 64)
            XCTAssertEqual(mkdirat(fd, name, 0o755), 0)
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY)
            close(fd)
            fd = next
        }
        close(fd)
        let run = try await ScanRun.run(home: deep.home)
        let issue = try XCTUnwrap(run.issues.first)
        XCTAssertTrue(issue.message.contains("errno 63"), issue.message)
        XCTAssertTrue(issue.message.contains("PATH_MAX"), issue.message)
        let box = try XCTUnwrap(run.summary?.roots.first)
        XCTAssertEqual(box.unlistedPathTooLong, 1, "what lies below is missing, and the partial view says why")
    }

    func testProgressReportsFilesBytesAndCurrentRoot() async throws {
        let collector = EventCollector()
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let store = try Inventory(path: ":memory:")
        try await store.recordScan(Scanner(roots: report.scanRoots()), homePath: tree.home) { collector.add($0) }
        let progress = collector.progress
        XCTAssertEqual(progress.first?.filesSeen, 0)
        XCTAssertEqual(progress.first?.currentRoot?.id, "icloud-drive/com~apple~CloudDocs")
        XCTAssertEqual(progress.first?.rootCount, 7)
        let last = try XCTUnwrap(progress.last)
        XCTAssertNil(last.currentRoot)
        XCTAssertEqual(last.filesSeen, 24)
        XCTAssertEqual(last.rootsCompleted, 7)
        XCTAssertEqual(last.bytesSeen, expected.values.reduce(0) { $0 + $1.logical })
        XCTAssertEqual(progress.map(\.filesSeen), progress.map(\.filesSeen).sorted(), "never goes backward")
    }

    func testCancelingTheConsumerStopsTheWalk() async throws {
        // Hold the walk thread after its first record until the consumer has canceled, so
        // the test does not depend on which side is faster.
        let gate = DispatchSemaphore(value: 0)
        let finished = expectation(description: "walk finished")
        let outcome = Outcome()
        var hooks = ScannerHooks()
        hooks.afterFile = { count in if count == 1 { gate.wait() } }
        hooks.walkFinished = { summary in
            outcome.set(summary)
            finished.fulfill()
        }
        let roots = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
        let scanner = Scanner(roots: roots, placeholderRule: .default, hooks: hooks)

        let consumer = Task {
            var files = 0
            for await event in scanner.scan(snapshotID: 1) {
                if case .file = event {
                    files += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            // The loop has ended, so the stream has terminated and the walk's flag is set.
            gate.signal()
            return files
        }
        let seen = await consumer.value
        await fulfillment(of: [finished], timeout: 10)
        let summary = try XCTUnwrap(outcome.value)
        XCTAssertEqual(seen, 1)
        XCTAssertTrue(summary.wasCanceled)
        XCTAssertLessThan(summary.files, 24)
        XCTAssertEqual(summary.roots.last?.wasInterrupted, true)
    }

    func testCanceledRecordScanMarksTheSnapshotCanceled() async throws {
        let roots = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
        let gate = DispatchSemaphore(value: 0)
        var hooks = ScannerHooks()
        hooks.afterFile = { count in if count == 1 { gate.wait() } }
        let scanner = Scanner(roots: roots, placeholderRule: .default, hooks: hooks)
        let store = try Inventory(path: ":memory:")
        let home = tree.home
        let task = Task {
            try await store.recordScan(scanner, homePath: home, batchSize: 1) { event in
                if case .file = event {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let id = try await task.value
        gate.signal()
        let snapshot = try await store.snapshot(id)
        XCTAssertEqual(snapshot?.status, .canceled)
        let totals = try await store.providerTotals(snapshotID: id, allowIncomplete: true)
        XCTAssertEqual(totals.reduce(0) { $0 + $1.files }, 1, "what was written before the cancel is kept")

        // The interrupted root has a row that agrees with the files table.
        let summaries = try await store.rootSummaries(snapshotID: id)
        XCTAssertEqual(summaries.map(\.root.id), ["icloud-drive/com~apple~CloudDocs"])
        XCTAssertEqual(summaries.first?.files, 1)
        XCTAssertEqual(summaries.first?.wasInterrupted, true)

        do {
            _ = try await store.providerTotals(snapshotID: id)
            XCTFail("totals of a canceled snapshot need allowIncomplete")
        } catch InventoryError.incompleteSnapshot(let failed, let status) {
            XCTAssertEqual(failed, id)
            XCTAssertEqual(status, .canceled)
        }
    }
}

final class ScannerMemoryTests: XCTestCase {
    /// The process's physical footprint, the number Activity Monitor shows as Memory.
    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
    }

    /// Without an autorelease pool per item, the walk thread kept about 12 KB per file until
    /// it exited (about 120 MB here). With it, growth stays at a few megabytes. The limit
    /// sits far from both, so allocator noise cannot flip the result.
    func testWalkMemoryStaysFlat() async throws {
        let tree = try FixtureTree(empty: true)
        defer { tree.remove() }
        let count = 10_000
        let folder = tree.path(FixtureTree.box + "/many")
        try tree.folder(FixtureTree.box + "/many")
        for index in 0..<count {
            let fd = open("\(folder)/file-\(index).txt", O_CREAT | O_EXCL | O_WRONLY, 0o644)
            XCTAssertGreaterThanOrEqual(fd, 0)
            close(fd)
        }
        let roots = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
        let baseline = footprint()
        XCTAssertGreaterThan(baseline, 0)
        var files = 0
        var peak = baseline
        for await event in Scanner(roots: roots).scan(snapshotID: 1) {
            guard case .file = event else { continue }
            files += 1
            if files % 500 == 0 { peak = max(peak, footprint()) }
        }
        XCTAssertEqual(files, count)
        let growth = Double(peak - baseline) / 1_048_576
        XCTAssertLessThan(growth, 40, "footprint grew \(growth) MB over \(count) files")
    }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var summary: ScanSummary?
    func set(_ value: ScanSummary) { lock.withLock { summary = value } }
    var value: ScanSummary? { lock.withLock { summary } }
}

extension Inventory {
    func allPaths(snapshotID: Int64) throws -> [String] {
        var collected: [String] = []
        try forEachFile(snapshotID: snapshotID) { collected.append($0.path) }
        return collected
    }
}
