import CryptoKit
import XCTest
@testable import CloudpaneCore

final class HashingTests: XCTestCase {
    private var tree: FixtureTree!
    private let folder = HashFolder(rootID: "dropbox/Dropbox", folder: "Docs")

    override func setUpWithError() throws {
        tree = try FixtureTree(empty: true)
        for index in 0..<30 { try tree.real(200_000 + index, FixtureTree.dropbox + "/Docs/f\(index).bin") }
        try tree.sparse(3_000_000, FixtureTree.dropbox + "/Docs/cloud-only.bin")
        try tree.real(0, FixtureTree.dropbox + "/Docs/empty.txt")
        try tree.real(100, FixtureTree.dropbox + "/Other/not-opted-in.txt")
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
        for record in try await store.search(snapshotID: id, text: ".", limit: 1000) {
            if let hash = record.sha256 { result[record.name] = hash }
        }
        return result
    }

    func testPlanCountsWhatWillDownloadAndHashingStoresCorrectHashes() async throws {
        let store = try Inventory(path: tree.base + "/hash.sqlite")
        let id = try await scan(store)
        try await store.setHashing(folder, enabled: true)
        let folders = try await store.hashFolders()
        XCTAssertEqual(folders, [folder])
        let plan = try await store.hashPlan(for: folders)
        XCTAssertEqual(plan.files, 31, "empty files and other folders are left out")
        XCTAssertEqual(plan.downloadFiles, 1)
        XCTAssertEqual(plan.downloadBytes, 3_000_000)
        XCTAssertEqual(plan.localFiles, 30)
        XCTAssertEqual(plan.localBytes, (0..<30).reduce(Int64(0)) { $0 + 200_000 + Int64($1) })

        let progress = ProgressLog()
        let policyBefore = MaterializationPolicy.currentThreadPolicy
        let summary = try await store.recordHashing(FileHasher(items: plan.items)) { progress.add($0) }
        XCTAssertEqual(MaterializationPolicy.currentThreadPolicy, policyBefore, "only the worker thread changed")
        XCTAssertEqual(summary?.hashed, 31)
        XCTAssertEqual(summary?.materializationEnabledOnWorker, true)
        XCTAssertEqual(progress.last?.filesDone, 31)
        XCTAssertEqual(progress.last?.bytesTotal, plan.bytes)
        XCTAssertTrue(progress.values.map(\.filesDone) == progress.values.map(\.filesDone).sorted())

        let stored = try await hashes(store, id)
        let expected = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: tree.path(FixtureTree.dropbox + "/Docs/f3.bin"))))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(stored["f3.bin"], expected)
        XCTAssertNil(stored["not-opted-in.txt"])
        let again = try await store.hashPlan(for: folders)
        XCTAssertEqual(again.files, 0)
        XCTAssertEqual(again.alreadyHashed, 31)
    }

    func testHashesCarryForwardUntilTheFileChanges() async throws {
        let store = try Inventory(path: tree.base + "/reuse.sqlite")
        _ = try await scan(store)
        try await store.setHashing(folder, enabled: true)
        try await store.recordHashing(FileHasher(items: try await store.hashPlan(for: [folder]).items))

        let unchanged = try await scan(store)
        let kept = try await hashes(store, unchanged)
        XCTAssertEqual(kept.count, 31, "an unchanged file keeps its hash in a later snapshot")

        // Same size, new content and date: the hash is dropped.
        try tree.real(200_005, FixtureTree.dropbox + "/Docs/f5.bin")
        try tree.setModified(FixtureTree.dropbox + "/Docs/f5.bin", Date(timeIntervalSince1970: 1_790_000_000))
        let changed = try await scan(store)
        let after = try await hashes(store, changed)
        XCTAssertNil(after["f5.bin"])
        XCTAssertEqual(after.count, 30)
        let awaited1 = try await store.hashPlan(for: [folder]).files
        XCTAssertEqual(awaited1, 1, "only the changed file needs hashing again")
    }

    func testCancelingStopsAndKeepsWhatWasHashed() async throws {
        let store = try Inventory(path: tree.base + "/cancel.sqlite")
        let id = try await scan(store)
        try await store.setHashing(folder, enabled: true)
        let plan = try await store.hashPlan(for: [folder])

        // Deterministic: the worker stops at the next check after a cancel.
        var checks = 0
        let summary = FileHasher.hashAll(plan.items, enabled: true, isCanceled: {
            checks += 1
            return checks > 5
        }, emit: { _ in })
        XCTAssertTrue(summary.wasCanceled)
        XCTAssertLessThan(summary.hashed, plan.files)

        // Through the inventory: a canceled task keeps the hashes it already received.
        let seen = ProgressLog()
        let task = Task {
            try await store.recordHashing(FileHasher(items: plan.items)) { event in
                if case .hashed = event {
                    seen.count()
                    if seen.hashedCount == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        }
        _ = try await task.value
        let stored = try await hashes(store, id)
        XCTAssertGreaterThanOrEqual(stored.count, 3)
        XCTAssertLessThan(stored.count, plan.files, "hashing stopped early")
        let awaited2 = try await store.hashPlan(for: [folder]).files
        XCTAssertEqual(awaited2, plan.files - stored.count, "partial progress is kept")
    }

    func testAFileThatChangesWhileBeingReadIsNotHashed() throws {
        let path = tree.path(FixtureTree.dropbox + "/Docs/f1.bin")
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        let stale = HashItem(path: path, size: Int64(info.st_size) + 1, modified: nil, inode: nil, isPlaceholder: false)
        guard case .failure(.changed) = FileHasher.hash(stale, isCanceled: { false }) else { return XCTFail("hashed a mismatched file") }
    }

    func testTheScannerKeepsMaterializationOff() async throws {
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        var summary: ScanSummary?
        for await event in Scanner(roots: report.scanRoots()).scan(snapshotID: 1) {
            if case .finished(let value) = event { summary = value }
        }
        XCTAssertEqual(summary?.materializationDisabled, true)
        let incremental = await IncrementalScanner(roots: report.scanRoots(), changedPaths: []).run(snapshotID: 1)
        XCTAssertTrue(incremental.materializationDisabled)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HashProgress] = []
    private var hashed = 0
    func add(_ event: HashEvent) {
        if case .progress(let value) = event { lock.withLock { items.append(value) } }
    }
    func count() { lock.withLock { hashed += 1 } }
    var hashedCount: Int { lock.withLock { hashed } }
    var values: [HashProgress] { lock.withLock { items } }
    var last: HashProgress? { values.last }
}
