import XCTest
@testable import CloudpaneCore

/// Acceptance target: known duplicates across two fake provider roots yield the expected
/// groups, tiers, ranking and placeholder flags, with no file in two tiers.
final class DuplicateTests: XCTestCase {
    private var tree: FixtureTree!
    private let when = Date(timeIntervalSince1970: 1_780_000_000)
    private let db = FixtureTree.dropbox
    private let gd = FixtureTree.googleDrive + "/My Drive"

    override func setUpWithError() throws { tree = try FixtureTree(empty: true) }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private func write(_ data: Data, _ path: String, at date: Date? = nil) throws {
        let full = path.hasPrefix("/") ? path : tree.path(path)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
        try tree.setModified(path, date ?? when)
    }

    private func sparse(_ size: Int64, _ path: String, at date: Date? = nil) throws {
        try tree.sparse(size, path)
        try tree.setModified(path, date ?? when)
    }

    private func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    private func scan(_ store: Inventory, backups: [String] = []) async throws -> Int64 {
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let roots = report.scanRoots(backups: backups.map { ScanRoot.backup(URL(fileURLWithPath: $0), label: "Desk drive") })
        return try await store.recordScan(Scanner(roots: roots), homePath: report.homePath)
    }

    private func hash(_ store: Inventory, _ folders: [HashFolder]) async throws -> HashSummary? {
        for folder in folders { try await store.setHashing(folder, enabled: true) }
        let plan = try await store.hashPlan(for: folders)
        return try await store.recordHashing(FileHasher(items: plan.items))
    }

    func testSeededDuplicatesAcrossTwoProvidersGroupAsExpected() async throws {
        let report = bytes(3000, seed: 1)
        // Exact: same content, different names, so only a hash can tell.
        try write(report, "\(db)/Reports/report.pdf")
        try write(report, "\(gd)/Reports/copy of report.pdf", at: when.addingTimeInterval(500))
        // Exact and strong at once: listed once, as exact.
        let notes = bytes(1500, seed: 2)
        try write(notes, "\(db)/Reports/notes.txt")
        try write(notes, "\(gd)/Reports/notes.txt")
        // Same name, size and date but different content, both hashed: not duplicates.
        try write(bytes(800, seed: 3), "\(db)/Reports/memo.txt")
        try write(bytes(800, seed: 4), "\(gd)/Reports/memo.txt")
        // Strong: placeholders, not hashed.
        try sparse(2_000_000, "\(db)/Photos/img.jpg")
        try sparse(2_000_000, "\(gd)/Photos/img.jpg", at: when.addingTimeInterval(1.5))
        // Weak: same size only, 5 MB, different names and dates.
        try sparse(5_000_000, "\(db)/Video/a.mov")
        try sparse(5_000_000, "\(gd)/Video/b.mov", at: when.addingTimeInterval(86_400))
        // Not duplicates: same size under 1 MB with different names; same name a day apart.
        try sparse(500_000, "\(db)/Misc/x.bin")
        try sparse(500_000, "\(gd)/Misc/y.bin")
        try sparse(700_000, "\(db)/Misc/z.bin")
        try sparse(700_000, "\(gd)/Misc/z.bin", at: when.addingTimeInterval(86_400))
        // A backup copy of the strong pair: listed with the group, never counted.
        try write(Data(count: 2_000_000), tree.backup + "/Photos/img.jpg")

        let store = try Inventory(path: tree.base + "/dups.sqlite")
        _ = try await scan(store, backups: [tree.backup])
        let hashedFolders = [HashFolder(rootID: "dropbox/Dropbox", folder: "Reports"),
                             HashFolder(rootID: "google-drive/GoogleDrive-test.user@example.com", folder: "My Drive/Reports")]
        let summary = try await hash(store, hashedFolders)
        XCTAssertEqual(summary?.hashed, 6)
        let id = try await scan(store, backups: [tree.backup])

        let result = try await store.duplicates(snapshotID: id)
        XCTAssertEqual(result.groups.map(\.tier), [.weak, .strong, .exact, .exact], "ranked by reclaimable bytes")
        XCTAssertEqual(result.groups.map(\.reclaimableBytes), [5_000_000, 2_000_000, 3000, 1500])
        XCTAssertEqual(result.groups.map { $0.copies.map(\.record.name).sorted() }, [
            ["a.mov", "b.mov"], ["img.jpg", "img.jpg"], ["copy of report.pdf", "report.pdf"], ["notes.txt", "notes.txt"],
        ])
        XCTAssertEqual(result.groups.map(\.placeholderCount), [2, 2, 0, 0])
        XCTAssertEqual(Set(result.groups[1].copies.map(\.locationName)), ["Dropbox", "Google Drive"])
        XCTAssertEqual(result.groups[1].backupCopies.map(\.locationName), ["Desk drive"])
        XCTAssertEqual(result.groups[1].copies.count, 2, "the backup copy is not counted")

        let paths = result.groups.flatMap { $0.copies.map(\.record.path) }
        XCTAssertEqual(paths.count, Set(paths).count, "no file in two groups or two tiers")
        XCTAssertFalse(paths.contains { $0.hasSuffix("memo.txt") }, "different hashes are not duplicates")
        XCTAssertEqual(result.totals.map(\.groups), [2, 1, 1])
        XCTAssertEqual(result.totalGroups, 4)
    }

    func testHashMismatchOverridesANameSizeAndDateMatchInTheGrade() async throws {
        // Test case s7: an unrelated return.pdf of the same size, created moments apart.
        try sparse(3_000_000, "\(db)/Taxes/return.pdf")
        try write(bytes(3_000_000, seed: 9), tree.backup + "/unrelated/return.pdf", at: when.addingTimeInterval(0.014))
        let store = try Inventory(path: tree.base + "/s7.sqlite")
        let facts = try ProviderFacts.bundled()
        let before = try await store.grade(snapshotID: try await scan(store, backups: [tree.backup]), facts: facts)
        XCTAssertEqual(before.folders.first?.letter, .B, "name, size and date match without hashes")

        let backupID = ScanRoot.backup(URL(fileURLWithPath: tree.backup)).id
        _ = try await hash(store, [HashFolder(rootID: "dropbox/Dropbox", folder: "Taxes"),
                                   HashFolder(rootID: backupID, folder: "unrelated")])
        let after = try await store.grade(snapshotID: try await scan(store, backups: [tree.backup]), facts: facts)
        XCTAssertEqual(after.folders.first?.letter, .F, "different hashes: the backup file is not a copy")
        XCTAssertEqual(after.singlePoint.files.map(\.name), ["return.pdf"])
    }
}

/// Duplicates and incremental merges must stay fast on a large, duplicate-heavy library.
final class DuplicatePerformanceTests: XCTestCase {
    /// 50,000 Dropbox placeholders and their 50,000 backup copies, names repeating 1,000
    /// times, dates spread over 20 seconds, as in the 200,000-file test case.
    static func largeInventory(path: String) async throws -> (Inventory, Int64) {
        let store = try Inventory(path: path)
        let id = try await store.beginSnapshot(homePath: "/h", placeholderRule: "test")
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var batch: [FileRecord] = []
        for index in 0..<50_000 {
            let name = "file_\(index % 1000)_with_a_long_name.dat"
            let date = base.addingTimeInterval(Double(index % 20_000) / 1000)
            for (provider, root, placeholder) in [("dropbox", "dropbox/Dropbox", true), ("backup", "backup/b", false)] {
                let folder = "folder_\(index / 1000)"
                batch.append(FileRecord(snapshotID: id, path: "/\(root)/\(folder)/\(name)", rootID: root, provider: provider,
                                        relativePath: "\(folder)/\(name)", name: name, topLevelFolder: folder,
                                        facts: FileFacts(logicalSize: 1000, allocatedSize: placeholder ? 0 : 4096),
                                        modified: date, isPackage: false, isPlaceholder: placeholder, contentType: nil,
                                        category: .other, inode: UInt64(index * 2 + (placeholder ? 0 : 1))))
            }
            if batch.count >= 10_000 {
                try await store.insert(batch)
                batch.removeAll()
            }
        }
        try await store.insert(batch)
        for (position, root) in [
            ScanRoot(id: "dropbox/Dropbox", kind: .provider, provider: "dropbox", providerName: "Dropbox",
                     name: "Dropbox", account: nil, path: "/dropbox/Dropbox"),
            ScanRoot(id: "backup/b", kind: .backup, provider: "backup", providerName: "Backup", name: "Disk",
                     account: nil, path: "/backup/b", backupKind: .externalDrive),
        ].enumerated() {
            try await store.insert(RootSummary(root: root), snapshotID: id, position: position)
        }
        try await store.finishSnapshot(id, status: .complete)
        return (store, id)
    }

    func testDuplicateQueryPlanAndTiming() async throws {
        let tree = try FixtureTree(empty: true)
        defer { tree.remove() }
        let (store, id) = try await Self.largeInventory(path: tree.base + "/big.sqlite")
        let plans = try await store.duplicateQueryPlans(snapshotID: id)
        for (tier, plan) in plans {
            XCTAssertTrue(plan.contains { $0.contains("files_open") }, "\(tier) reads only current versions: \(plan)")
        }
        let clock = ContinuousClock()
        var report: DuplicateReport?
        let elapsed = try await clock.measure { report = try await store.duplicates(snapshotID: id) }
        print("duplicates on 100,000 rows:", elapsed)

        let groups = try XCTUnwrap(report?.groups)
        XCTAssertFalse(groups.isEmpty)
        for group in groups where group.tier == .strong {
            let dates = group.copies.compactMap(\.record.modified)
            XCTAssertGreaterThanOrEqual(group.copies.count, 2)
            XCTAssertLessThanOrEqual((dates.max()!).timeIntervalSince(dates.min()!), Inventory.matchWindow,
                                     "a strong group spans more than 2 seconds")
            XCTAssertFalse(group.backupCopies.isEmpty, "the backup holds every file")
        }
        let copies = groups.flatMap { $0.copies.map(\.record.path) }
        XCTAssertEqual(copies.count, Set(copies).count, "no file in two groups")
        XCTAssertLessThan(elapsed, .seconds(5), "duplicates took \(elapsed)")
    }

    /// Memory stays flat: a library of unique files is never loaded into memory just to find
    /// that nothing repeats. Loading every row, as the first M4 version did, grew by hundreds
    /// of megabytes on a 420,000-row test database.
    func testDuplicatesDoNotLoadTheLibrary() async throws {
        let tree = try FixtureTree(empty: true)
        defer { tree.remove() }
        let store = try Inventory(path: tree.base + "/unique.sqlite")
        let id = try await store.beginSnapshot(homePath: "/h", placeholderRule: "test")
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var batch: [FileRecord] = []
        for index in 0..<150_000 {
            // Unique names and sizes, except ten pairs of strong duplicates at the end.
            let pair = index >= 149_980
            let name = pair ? "pair_\((index - 149_980) / 2).dat" : "unique_\(index)_with_a_long_descriptive_name.dat"
            let size = pair ? Int64(5_000 + (index - 149_980) / 2) : Int64(10_000_000 + index)
            let path = "/dropbox/Dropbox/folder_\(index / 1000)/\(pair ? "\(index)-" : "")\(name)"
            batch.append(FileRecord(snapshotID: id, path: path, rootID: "dropbox/Dropbox", provider: "dropbox",
                                    relativePath: String(path.dropFirst("/dropbox/Dropbox/".count)), name: name,
                                    topLevelFolder: "folder_\(index / 1000)",
                                    facts: FileFacts(logicalSize: size, allocatedSize: 0), modified: base,
                                    isPackage: false, isPlaceholder: true, contentType: nil, category: .other,
                                    inode: UInt64(index)))
            if batch.count >= 10_000 {
                try await store.insert(batch)
                batch.removeAll()
            }
        }
        try await store.insert(batch)
        try await store.insert(RootSummary(root: ScanRoot(id: "dropbox/Dropbox", kind: .provider, provider: "dropbox",
                                                          providerName: "Dropbox", name: "Dropbox", account: nil,
                                                          path: "/dropbox/Dropbox")), snapshotID: id, position: 0)
        try await store.finishSnapshot(id, status: .complete)

        let before = Self.footprint()
        let sampler = FootprintSampler()
        let sampling = Task.detached { await sampler.run() }
        let report = try await store.duplicates(snapshotID: id)
        sampling.cancel()
        let peak = max(await sampler.peak, Self.footprint())
        let growth = Double(peak - before) / 1_048_576
        print("duplicates footprint growth on 150,000 rows:", String(format: "%.1f MB", growth))
        XCTAssertEqual(report.totals.first { $0.tier == .strong }?.groups, 10)
        XCTAssertEqual(report.totals.first { $0.tier == .weak }?.groups, 0, "unique sizes, no weak groups")
        XCTAssertLessThan(growth, 20, "duplicates grew the footprint by \(growth) MB")
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// A full rescan that finds nothing changed writes no versions, and the merge is quick.
    func testMergingAnUnchangedFullRescanWritesNothing() async throws {
        let tree = try FixtureTree(empty: true)
        defer { tree.remove() }
        let (store, first) = try await Self.largeInventory(path: tree.base + "/merge.sqlite")
        let before = try await store.versionCount()
        let id = try await store.beginSnapshot(homePath: "/h", placeholderRule: "test")
        var copy: [FileRecord] = []
        try await store.forEachFileForTest(snapshotID: first) { record in
            copy.append(FileRecord(snapshotID: id, path: record.path, rootID: record.rootID, provider: record.provider,
                                   relativePath: record.relativePath, name: record.name,
                                   topLevelFolder: record.topLevelFolder, facts: record.facts,
                                   modified: record.modified, isPackage: record.isPackage,
                                   isPlaceholder: record.isPlaceholder, contentType: record.contentType,
                                   category: record.category, inode: record.inode))
        }
        try await store.insert(copy)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { try await store.finishSnapshot(id, status: .complete) }
        let after = try await store.versionCount()
        XCTAssertEqual(after, before, "100,000 unchanged files, no new rows")
        XCTAssertLessThan(elapsed, .seconds(10), "merge took \(elapsed)")
    }
}

extension Inventory {
    func forEachFileForTest(snapshotID: Int64, _ body: (FileRecord) -> Void) throws {
        try forEachFile(snapshotID: snapshotID, body)
    }
}

/// Samples the process footprint every 10 ms until canceled.
actor FootprintSampler {
    private(set) var peak: Int64 = 0
    func run() async {
        while !Task.isCancelled {
            peak = max(peak, DuplicatePerformanceTests.footprint())
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
