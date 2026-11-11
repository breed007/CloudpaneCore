import XCTest
@testable import CloudpaneCore

/// Fixes from the M4 test round: hashing never downloads without confirmation, history is
/// immutable, scans are serialized, canceled scans do not pile up, and duplicate windows
/// are anchored.
final class QAFixTests: XCTestCase {
    private var tree: FixtureTree!
    private let folder = HashFolder(rootID: "dropbox/Dropbox", folder: "Docs")

    override func setUpWithError() throws {
        tree = try FixtureTree(empty: true)
        for index in 0..<5 { try tree.real(100_000 + index, FixtureTree.dropbox + "/Docs/f\(index).bin") }
        try tree.sparse(2_000_000, FixtureTree.dropbox + "/Docs/cloud.bin")
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private func scan(_ store: Inventory) async throws -> Int64 {
        try await ScanRun.run(home: tree.home, inventory: store).snapshotID
    }

    private func hashes(_ store: Inventory, _ id: Int64) async throws -> [String: String] {
        var result: [String: String] = [:]
        for record in try await store.search(snapshotID: id, text: ".bin", limit: 100) {
            if let hash = record.sha256 { result[record.name] = hash }
        }
        return result
    }

    // MARK: 1a

    func testAFileEvictedSinceThePlanIsNeverDownloaded() async throws {
        let store = try Inventory(path: tree.base + "/evict.sqlite")
        _ = try await scan(store)
        let plan = try await store.hashPlan(for: [folder])
        let local = try XCTUnwrap(plan.items.first { $0.path.hasSuffix("f0.bin") })
        XCTAssertFalse(local.allowDownload, "a file on the Mac is not a confirmed download")
        let cloud = try XCTUnwrap(plan.items.first { $0.path.hasSuffix("cloud.bin") })
        XCTAssertTrue(cloud.allowDownload, "the cloud-only file in the confirmed plan may download")

        // Eviction keeps size, dates and inode; only the dataless flag changes. Simulate it.
        let evicted = FileHasher.hashAll([local, cloud], enabled: true, isCanceled: { false },
                                         isDataless: { _ in true }, emit: { _ in })
        XCTAssertEqual(evicted.needsConfirmation, 1, "the evicted local file waits for confirmation")
        XCTAssertEqual(evicted.hashed, 1, "the confirmed cloud-only file is hashed")
    }

    /// Evicted between lstat and open: the check on the open descriptor catches it, and
    /// nothing is read.
    func testAFileEvictedAfterLstatIsNotRead() async throws {
        let store = try Inventory(path: tree.base + "/race.sqlite")
        _ = try await scan(store)
        let plan = try await store.hashPlan(for: [folder])
        let local = try XCTUnwrap(plan.items.first { $0.path.hasSuffix("f0.bin") })
        let checks = CheckCounter()
        // Not dataless at lstat, dataless by the time it is open.
        let result = FileHasher.hash(local, isCanceled: { false }, isDataless: { _ in checks.next() > 1 })
        guard case .failure(.needsConfirmation) = result else { return XCTFail("read an evicted file: \(result)") }
        XCTAssertEqual(checks.count, 2, "checked at lstat and again on the open descriptor")
    }

    func testTheAutomaticPassKeepsMaterializationOff() async throws {
        let store = try Inventory(path: tree.base + "/auto.sqlite")
        _ = try await scan(store)
        let plan = try await store.hashPlan(for: [folder])
        let hasher = FileHasher(items: plan.items.filter { !$0.isPlaceholder }, allowsDownloads: false)
        XCTAssertTrue(hasher.items.allSatisfy { !$0.allowDownload })
        let summary = try await store.recordHashing(hasher)
        XCTAssertEqual(summary?.materializationEnabledOnWorker, false)
        XCTAssertEqual(summary?.hashed, 5)
    }

    // MARK: 1b

    func testOnlyTheConfirmedItemsAreHashed() async throws {
        let store = try Inventory(path: tree.base + "/confirmed.sqlite")
        _ = try await scan(store)
        let confirmed = try await store.hashPlan(for: [folder])
        // A cloud-only file appears after the sheet showed its counts.
        try tree.sparse(9_000_000, FixtureTree.dropbox + "/Docs/late.bin")
        let id = try await scan(store)
        try await store.recordHashing(FileHasher(items: confirmed.items))
        let stored = try await hashes(store, id)
        XCTAssertEqual(Set(stored.keys), Set(confirmed.items.map { ($0.path as NSString).lastPathComponent }))
        XCTAssertNil(stored["late.bin"], "a file the user never saw in the sheet is not downloaded")
        let next = try await store.hashPlan(for: [folder])
        XCTAssertEqual(next.downloadFiles, 1, "it waits for the next confirmation")
    }

    // MARK: 3

    func testRepeatedCancelsDoNotGrowTheDatabase() async throws {
        for index in 0..<300 { try tree.real(100, FixtureTree.dropbox + "/Many/m\(index).txt") }
        let store = try Inventory(path: tree.base + "/cancel.sqlite")
        _ = try await scan(store)
        let roots = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
        let home = tree.home
        var stagedCounts: [Int] = []
        for _ in 0..<4 {
            let gate = DispatchSemaphore(value: 0)
            var hooks = ScannerHooks()
            hooks.afterFile = { count in if count == 150 { gate.wait() } }
            let scanner = Scanner(roots: roots, placeholderRule: .default, hooks: hooks)
            let task = Task {
                try await store.recordScan(scanner, homePath: home, batchSize: 10) { event in
                    if case .file = event { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            _ = try await task.value
            gate.signal()
            stagedCounts.append(try await store.stagedCount())
        }
        XCTAssertTrue(stagedCounts.allSatisfy { $0 > 0 && $0 <= stagedCounts[0] }, "\(stagedCounts)")
        XCTAssertEqual(stagedCounts.count, 4)
        _ = try await scan(store)
        let afterComplete = try await store.stagedCount()
        XCTAssertEqual(afterComplete, 0, "a completed scan leaves no staged rows behind")
    }

    // MARK: 5

    func testASameSizeEditThatRestoresTheDateDropsTheHash() async throws {
        let store = try Inventory(path: tree.base + "/ctime.sqlite")
        _ = try await scan(store)
        try await store.recordHashing(FileHasher(items: try await store.hashPlan(for: [folder]).items.filter { !$0.isPlaceholder }))
        let path = tree.path(FixtureTree.dropbox + "/Docs/f1.bin")
        var original = stat()
        XCTAssertEqual(lstat(path, &original), 0)
        // touch -r style: new content, same size, the original modification date restored to
        // the nanosecond, so only the inode change time can tell.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 100))
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0)
        var edited = stat()
        XCTAssertEqual(lstat(path, &edited), 0)
        XCTAssertEqual(edited.st_mtimespec.tv_nsec, original.st_mtimespec.tv_nsec)
        XCTAssertEqual(edited.st_size, original.st_size)
        XCTAssertEqual(edited.st_ino, original.st_ino)
        let id = try await scan(store)
        let stored = try await hashes(store, id)
        XCTAssertNil(stored["f1.bin"], "the inode change time gave the edit away")
        XCTAssertNotNil(stored["f0.bin"])
    }

    // MARK: 6

    func testScansAndUpdatesRunOneAtATime() async throws {
        let store = try Inventory(path: tree.base + "/serial.sqlite")
        _ = try await scan(store)
        for index in 0..<200 { try tree.real(10, FixtureTree.dropbox + "/Burst/b\(index).txt") }
        let roots = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
        let changed = Set((0..<200).map { tree.path(FixtureTree.dropbox + "/Burst/b\($0).txt") })
        let home = tree.home
        async let update = store.recordIncremental(IncrementalScanner(roots: roots, changedPaths: changed), homePath: home)
        async let full = store.recordScan(Scanner(roots: roots), homePath: home)
        let (outcome, fullID) = try await (update, full)
        guard case .recorded(let updateID) = outcome else { return XCTFail("\(outcome)") }
        let a = try await store.snapshot(updateID)
        let b = try await store.snapshot(fullID)
        let (first, second) = a!.startedAt < b!.startedAt ? (a!, b!) : (b!, a!)
        XCTAssertLessThanOrEqual(first.finishedAt!, second.startedAt, "the two writers overlapped")
        let totalsA = try await store.providerTotals(snapshotID: updateID, allowIncomplete: true)
        let totalsB = try await store.providerTotals(snapshotID: fullID, allowIncomplete: true)
        XCTAssertEqual(totalsA, totalsB)
    }

    // MARK: 9

    func testHashingDoesNotRewriteEarlierSnapshots() async throws {
        let store = try Inventory(path: tree.base + "/history.sqlite")
        let first = try await scan(store)
        let second = try await scan(store)
        try await store.recordHashing(FileHasher(items: try await store.hashPlan(for: [folder]).items.filter { !$0.isPlaceholder }))
        let before = try await hashes(store, first)
        let after = try await hashes(store, second)
        XCTAssertTrue(before.isEmpty, "the earlier snapshot never had hashes")
        XCTAssertEqual(after.count, 5)
        let diff = try await store.diff(from: first, to: second)
        XCTAssertEqual(diff.addedCount + diff.removedCount + diff.changedCount + diff.movedCount, 0)
        let third = try await scan(store)
        let carried = try await hashes(store, third)
        XCTAssertEqual(carried.count, 5, "later snapshots keep the hash")
    }

    // MARK: Hard links

    func testAHardLinkAddedBetweenFullScansIsNotASecondFile() async throws {
        let store = try Inventory(path: tree.base + "/links.sqlite")
        let first = try await scan(store)
        try tree.hardLink(FixtureTree.dropbox + "/Docs/f2.bin", FixtureTree.dropbox + "/Docs/link.bin")
        let roots = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
        let outcome = try await store.recordIncremental(
            IncrementalScanner(roots: roots, changedPaths: [tree.path(FixtureTree.dropbox + "/Docs/link.bin")]),
            homePath: tree.home)
        guard case .recorded(let id) = outcome else { return XCTFail("\(outcome)") }
        let a = try await store.providerTotals(snapshotID: first)
        let b = try await store.providerTotals(snapshotID: id)
        XCTAssertEqual(a.first?.files, b.first?.files)
        let report = try await store.duplicates(snapshotID: id)
        XCTAssertEqual(report.totalGroups, 0, "a hard link is not a duplicate")
    }

    // MARK: Strong windows

    func testStrongGroupsAreAnchoredWithinTwoSeconds() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func candidate(_ offset: Double) -> DuplicateFinder.Candidate {
            let record = FileRecord(snapshotID: 1, path: "/x/\(offset)", rootID: "r", provider: "p", relativePath: "\(offset)",
                                    name: "a", topLevelFolder: "", facts: FileFacts(logicalSize: 10, allocatedSize: 0),
                                    modified: base.addingTimeInterval(offset), isPackage: false, isPlaceholder: true,
                                    contentType: nil, category: .other)
            return DuplicateFinder.Candidate(rowid: Int64(offset * 10), record: record, locationName: "P")
        }
        let clusters = DuplicateFinder.clusters([0, 1.5, 3, 4.5, 6].map(candidate))
        XCTAssertEqual(clusters.map { $0.map { $0.record.relativePath } }, [["0.0", "1.5"], ["3.0", "4.5"]],
                       "chained neighbors 1.5 s apart no longer make one 6-second group")
    }
}

extension Inventory {
    func stagedCount() throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM files WHERE staged = 1")
        _ = try statement.step()
        return statement.int(0)
    }
}

final class CheckCounter: @unchecked Sendable {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
