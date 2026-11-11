import XCTest
@testable import CloudpaneCore

final class MigrationTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws { tree = try FixtureTree(empty: true) }
    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    /// A database exactly as M2 left it, with a scan in it.
    private func makeVersion2Database(at path: String) throws {
        let db = try SQLiteConnection(path: path)
        try db.execute(Inventory.schemaV2 + "PRAGMA user_version = 2;")
        try db.execute("""
            INSERT INTO snapshots VALUES (1, 1790000000, 1790000060, 'complete', '/Users/someone', 'dataless-or-strict-v1');
            INSERT INTO snapshot_roots VALUES (1, 0, 'dropbox/Dropbox', 'provider', 'dropbox', 'Dropbox', 'Dropbox',
                NULL, '/Users/someone/Library/CloudStorage/Dropbox', 1, 2, 0, 1, 0, 3000, 4096, 1, 2000, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 12.5, 0);
            INSERT INTO files VALUES (1, '/Users/someone/Library/CloudStorage/Dropbox/Docs/a.txt', 'dropbox/Dropbox',
                'dropbox', 'Docs/a.txt', 'a.txt', 'a.txt', '/users/someone/library/cloudstorage/dropbox/docs/a.txt',
                'Docs', 1000, 4096, 1790000000, 0, 'none', 0, 0, 0, 0, 'public.plain-text', 'document', NULL);
            INSERT INTO files VALUES (1, '/Users/someone/Library/CloudStorage/Dropbox/Docs/b.pdf', 'dropbox/Dropbox',
                'dropbox', 'Docs/b.pdf', 'b.pdf', 'b.pdf', '/users/someone/library/cloudstorage/dropbox/docs/b.pdf',
                'Docs', 2000, 0, 1790000000, 0, 'none', 0, 0, 0, 1, 'com.adobe.pdf', 'document', NULL);
            """)
    }

    func testVersion2DatabaseMigratesWithoutLosingData() async throws {
        let path = tree.base + "/v2.sqlite"
        try makeVersion2Database(at: path)

        let store = try Inventory(path: path)
        let value1 = try await store.schemaVersion()
        XCTAssertEqual(value1, 9)
        let snapshots = try await store.snapshots()
        XCTAssertEqual(snapshots.map(\.id), [1])
        XCTAssertEqual(snapshots.first?.status, .complete)
        let totals = try await store.providerTotals(snapshotID: 1)
        XCTAssertEqual(totals.first?.files, 2)
        XCTAssertEqual(totals.first?.logicalBytes, 3000)
        XCTAssertEqual(totals.first?.placeholderBytes, 2000)
        let roots = try await store.rootSummaries(snapshotID: 1)
        XCTAssertEqual(roots.first?.root.id, "dropbox/Dropbox")
        XCTAssertNil(roots.first?.root.backupKind, "old rows read with the new columns' defaults")
        XCTAssertEqual(roots.first?.root.isOffsite, false)
        let found = try await store.search(snapshotID: 1, text: "B.PDF")
        XCTAssertEqual(found.map(\.name), ["b.pdf"])
        let value2 = try await store.subscriptions()
        XCTAssertEqual(value2, [])
        let value3 = try await store.backupLocations()
        XCTAssertEqual(value3, [])
        let value4 = try await store.usageHistory().map(\.usedBytes)
        XCTAssertEqual(value4, [["dropbox": 3000]])

        // The new tables work in the migrated database, and reopening is a no-op.
        try await store.save(Subscription(provider: "dropbox", name: "Plus", price: 11.99, currency: "USD"))
        let reopened = try Inventory(path: path)
        let value5 = try await reopened.subscriptions().map(\.name)
        XCTAssertEqual(value5, ["Plus"])
        let value6 = try await reopened.providerTotals(snapshotID: 1).first?.files
        XCTAssertEqual(value6, 2)
    }

    /// Version 3 kept a full copy of every row per snapshot. After moving to versioned rows
    /// each snapshot must read exactly as before.
    func testVersion3HistoryReadsTheSameAfterMigration() async throws {
        let path = tree.base + "/v3.sqlite"
        let db = try SQLiteConnection(path: path)
        try db.execute(Inventory.schemaV2 + Inventory.migrationV3 + "PRAGMA user_version = 3;")
        func file(_ snapshot: Int, _ name: String, _ size: Int) -> String {
            """
            INSERT INTO files VALUES (\(snapshot), '/d/\(name)', 'dropbox/Dropbox', 'dropbox', '\(name)', '\(name)',
                '\(name)', '/d/\(name)', '', \(size), 4096, 1790000000, 0, 'none', 0, 0, 0, 0, NULL, 'other', NULL);
            """
        }
        try db.execute("""
            INSERT INTO snapshots VALUES (1, 1790000000, 1790000060, 'complete', '/h', 'r');
            INSERT INTO snapshots VALUES (2, 1790100000, 1790100060, 'complete', '/h', 'r');
            INSERT INTO snapshots VALUES (3, 1790200000, NULL, 'canceled', '/h', 'r');
            \(file(1, "a.txt", 100)) \(file(1, "b.txt", 200))
            \(file(2, "a.txt", 100)) \(file(2, "c.txt", 300))
            \(file(3, "a.txt", 100))
            """)
        let store = try Inventory(path: path)
        let version = try await store.schemaVersion()
        XCTAssertEqual(version, 9)
        let one = try await store.providerTotals(snapshotID: 1)
        let two = try await store.providerTotals(snapshotID: 2)
        let three = try await store.providerTotals(snapshotID: 3, allowIncomplete: true)
        XCTAssertEqual(one.first?.logicalBytes, 300)
        XCTAssertEqual(two.first?.logicalBytes, 400)
        XCTAssertEqual(three.first?.logicalBytes, 100, "the canceled scan still sees only its own rows")
        let diff = try await store.diff(from: 1, to: 2)
        XCTAssertEqual(diff.added.map(\.name), ["c.txt"])
        XCTAssertEqual(diff.removed.map(\.name), ["b.txt"])
        XCTAssertEqual(diff.changedCount, 0, "a.txt is the same file in both")
        let folders = try await store.hashFolders()
        XCTAssertEqual(folders, [], "the hash opt-in table exists")
    }

    func testVersion1IsStillRefused() throws {
        let path = tree.base + "/v1.sqlite"
        try SQLiteConnection(path: path).execute("PRAGMA user_version = 1")
        XCTAssertThrowsError(try Inventory(path: path)) { error in
            guard case InventoryError.unsupportedSchema(1) = error else { return XCTFail("\(error)") }
            XCTAssertFalse("\(error)".lowercased().contains("delete"))
        }
    }

    func testNewerSchemaIsLeftUntouched() throws {
        let path = tree.base + "/v99.sqlite"
        try SQLiteConnection(path: path).execute("CREATE TABLE future (x); PRAGMA user_version = 99;")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try Inventory(path: path)) { error in
            guard case InventoryError.newerSchema(99) = error else { return XCTFail("\(error)") }
            XCTAssertTrue("\(error)".contains("newer version of Cloudpane"))
            XCTAssertFalse("\(error)".lowercased().contains("delete"))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "not a byte changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
    }

    func testGrowthBaselineIsChosenByTimeNotByCount() async throws {
        let store = try Inventory(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func complete(at date: Date, used: Int64) async throws {
            let id = try await store.beginSnapshot(homePath: "/h", placeholderRule: "test", startedAt: date)
            var summary = RootSummary(root: ScanRoot(id: "dropbox/Dropbox", kind: .provider, provider: "dropbox",
                                                     providerName: "Dropbox", name: "Dropbox", account: nil, path: "/d"))
            summary.logicalBytes = used
            try await store.insert(summary, snapshotID: id, position: 0)
            try await store.finishSnapshot(id, status: .complete, finishedAt: date)
        }
        try await complete(at: start, used: 1000)
        try await complete(at: start.addingTimeInterval(86_400 * 2 - 600), used: 1500)
        // Thirty scans in the last few minutes must not hide the scan two days back.
        for minute in 0..<30 {
            try await complete(at: start.addingTimeInterval(86_400 * 2 + Double(minute) * 10), used: 2000)
        }
        // The baseline is the newest scan at least a day older than the latest: the one two
        // days back, not the one ten minutes before the burst.
        let history = try await store.usageHistory()
        XCTAssertEqual(history.map { $0.usedBytes["dropbox"] }, [1000, 2000])
        XCTAssertEqual(history.first?.finishedAt, start)
    }

    func testSubscriptionsRoundTripAndOnePerProvider() async throws {
        let store = try Inventory(path: ":memory:")
        let next = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = try await store.save(Subscription(
            provider: "google-drive", name: "Google AI Pro 5 TB", price: Decimal(string: "19.99")!, currency: "usd",
            cycle: .year, frequency: 2, nextPayment: next, paymentMethod: "Card", category: "Cloud storage",
            url: "https://example.com", notes: "Family plan", autoRenew: false, inactive: true,
            planBytes: 5_000_000_000_000, bundle: .googleOneFamily))
        let id = try XCTUnwrap(saved.id)
        let loaded = try await store.subscriptions()
        XCTAssertEqual(loaded, [saved])
        XCTAssertEqual(loaded.first?.price, Decimal(string: "19.99"), "price survives exactly")
        XCTAssertEqual(loaded.first?.currency, "USD")

        do {
            try await store.save(Subscription(provider: "google-drive", name: "Second", price: 1, currency: "USD"))
            XCTFail("one plan per provider")
        } catch let error as PlanError {
            XCTAssertEqual(error, .providerTaken("google-drive"))
        }
        do {
            try await store.save(Subscription(provider: "box", name: "", price: -1, currency: "USD"))
            XCTFail("invalid plans are refused")
        } catch PlanError.invalid(let problems) {
            XCTAssertEqual(problems.count, 2)
        }

        var edited = saved
        edited.price = 25
        edited.inactive = false
        try await store.save(edited)
        let value7 = try await store.subscriptions().first?.price
        XCTAssertEqual(value7, 25)
        try await store.deleteSubscription(id: id)
        let value8 = try await store.subscriptions()
        XCTAssertEqual(value8, [])
    }

    func testBackupLocationsRoundTripAndRemovalDeletesTheBookmark() async throws {
        let store = try Inventory(path: ":memory:")
        let bookmark = Data([1, 2, 3, 4])
        let saved = try await store.save(BackupLocation(path: "/Volumes/Archive", label: "Archive disk",
                                                         kind: .externalDrive, isOffsite: true, bookmark: bookmark))
        var loaded = try await store.backupLocations()
        XCTAssertEqual(loaded.map(\.bookmark), [bookmark])
        XCTAssertEqual(loaded.first?.scanRoot.backupKind, .externalDrive)
        XCTAssertEqual(loaded.first?.scanRoot.isOffsite, true)
        XCTAssertEqual(loaded.first?.scanRoot.name, "Archive disk")

        var relabeled = saved
        relabeled.kind = .nasShare
        relabeled.isOffsite = false
        try await store.save(relabeled)
        loaded = try await store.backupLocations()
        XCTAssertEqual(loaded.map(\.kind), [.nasShare])

        try await store.removeBackupLocation(id: try XCTUnwrap(saved.id))
        let value9 = try await store.backupLocations()
        XCTAssertEqual(value9, [])
    }

    func testUsageHistoryUsesCompleteScansOnly() async throws {
        let store = try Inventory(path: ":memory:")
        try tree.real(1000, FixtureTree.dropbox + "/a.txt")
        _ = try await ScanRun.run(home: tree.home, inventory: store)
        try tree.real(500, FixtureTree.dropbox + "/b.txt")
        _ = try await ScanRun.run(home: tree.home, inventory: store)
        _ = try await store.beginSnapshot(homePath: tree.home, placeholderRule: "test")  // never finishes
        let history = try await store.usageHistory()
        XCTAssertEqual(history.map { $0.usedBytes["dropbox"] }, [1000, 1500])
        XCTAssertTrue(history[0].finishedAt <= history[1].finishedAt)
    }
}

extension Inventory {
    func schemaVersion() throws -> Int64 { try db.integerPragma("user_version") }
}
