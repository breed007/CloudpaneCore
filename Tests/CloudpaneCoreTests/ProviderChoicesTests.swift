import CoreServices
import XCTest
@testable import CloudpaneCore

/// Custom providers, excluded accounts and forgotten accounts (schema 9).
final class ProviderChoicesTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws { tree = try FixtureTree() }
    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private var contoso: String { canonicalPath(tree.path(FixtureTree.oneDriveContoso)) }
    private var proton: String { canonicalPath(tree.path(FixtureTree.cloudStorage + "/ProtonDrive-test")) }

    private func catalog() -> CatalogReport { ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect() }

    // MARK: - Schema

    func testVersion8DatabaseGainsTheChoiceTables() async throws {
        let path = tree.base + "/v8.sqlite"
        let db = try SQLiteConnection(path: path)
        try db.execute(Inventory.schemaV2 + Inventory.migrationV3 + Inventory.migrationV4 + Inventory.migrationV5
                       + Inventory.migrationV6 + Inventory.migrationV7 + Inventory.migrationV8 + "PRAGMA user_version = 8;")
        try db.execute("""
            INSERT INTO snapshots (id, started_at, finished_at, status, home_path, placeholder_rule)
                VALUES (1, 1790000000, 1790000060, 'complete', '/h', 'r');
            INSERT INTO subscriptions (provider, name, price, currency, cycle, frequency, payment_method, category,
                url, notes, auto_renew, inactive, updated_at)
                VALUES ('dropbox', 'Plus', '11.99', 'USD', 'month', 1, '', '', '', '', 1, 0, 1790000000);
            """)
        let store = try Inventory(path: path)
        let version = try await store.schemaVersion()
        XCTAssertEqual(version, 9)
        let snapshots = try await store.snapshots()
        XCTAssertEqual(snapshots.map(\.id), [1])
        let plans = try await store.subscriptions()
        XCTAssertEqual(plans.map(\.name), ["Plus"])
        let choices = try await store.scanChoices()
        XCTAssertEqual(choices, ScanChoices())
    }

    // MARK: - Custom providers

    func testCustomProvidersAreStoredAndRemovingOneRemovesItsPlan() async throws {
        let store = try Inventory(path: ":memory:")
        let costOnly = try await store.save(CustomProvider(name: "  Photo vault  "))
        XCTAssertEqual(costOnly.name, "Photo vault")
        XCTAssertTrue(costOnly.isCostOnly)
        let named = try await store.save(CustomProvider(name: "Proton", folderName: "ProtonDrive-test"))
        XCTAssertFalse(named.isCostOnly)
        XCTAssertNotEqual(costOnly.providerID, named.providerID)
        XCTAssertTrue(CustomProvider.isCustom(named.providerID))

        do {
            try await store.save(CustomProvider(name: "Again", folderName: "ProtonDrive-test"))
            XCTFail("a folder took a second name")
        } catch let error as PlanError {
            XCTAssertEqual(error, .invalid(["ProtonDrive-test already has the name Proton."]))
        }
        do {
            try await store.save(CustomProvider(name: " "))
            XCTFail("an empty name was saved")
        } catch let error as PlanError {
            XCTAssertEqual(error, .invalid(["Enter a name."]))
        }

        // A custom provider owns one plan, like a built-in one.
        try await store.save(Subscription(provider: costOnly.providerID, name: "Vault 2 TB", price: 5, currency: "USD"))
        try await store.save(Subscription(provider: "dropbox", name: "Plus", price: 12, currency: "USD"))
        try await store.removeCustomProvider(id: try XCTUnwrap(costOnly.id))
        let plans = try await store.subscriptions()
        XCTAssertEqual(plans.map(\.provider), ["dropbox"], "the plan went with its provider; others stay")
        let left = try await store.customProviders()
        XCTAssertEqual(left.map(\.name), ["Proton"])
    }

    /// A removed provider's id is never given to a new one, so a new provider can never take
    /// over the rows, root totals and history points past scans filed under the old id.
    func testARemovedProvidersIdIsNeverReused() async throws {
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        _ = try await store.save(CustomProvider(name: "First", folderName: "ProtonDrive-test"))
        let second = try await store.save(CustomProvider(name: "Second"))
        // Past scans hold rows under the second provider's id.
        let choices = ScanChoices(customProviders: [CustomProvider(id: second.id, name: "Second",
                                                                    folderName: "ProtonDrive-test")])
        let id = try await store.recordScan(Scanner(roots: catalog().scanRoots(choices: choices)), homePath: tree.home)
        let before = try await store.providerTotals(snapshotID: id)
        XCTAssertTrue(before.contains { $0.provider == second.providerID })

        try await store.removeCustomProvider(id: try XCTUnwrap(second.id))
        let third = try await store.save(CustomProvider(name: "Third"))
        XCTAssertNotEqual(third.providerID, second.providerID)
        XCTAssertGreaterThan(try XCTUnwrap(third.id), try XCTUnwrap(second.id))
        let history = try await store.totalsHistory()
        XCTAssertFalse(history.contains { $0.provider == third.providerID }, "the new provider has no history")
        XCTAssertTrue(history.contains { $0.provider == second.providerID && $0.providerName == "Second" },
                      "the old rows keep the removed provider's last name")
    }

    func testLookalikeNamesAreRefused() async throws {
        let store = try Inventory(path: ":memory:")
        for name in ["Dropbox", "dropbox", "ONEDRIVE", "Other cloud folders"] {
            do {
                try await store.save(CustomProvider(name: name))
                XCTFail("\(name) was accepted")
            } catch let error as PlanError {
                XCTAssertTrue(error.description.contains("Choose another name"), error.description)
            }
        }
        try await store.save(CustomProvider(name: "Café vault"))
        // The same name typed decomposed and in another case is the same name.
        let decomposed = "CAFE\u{301} VAULT"
        do {
            try await store.save(CustomProvider(name: decomposed))
            XCTFail("a lookalike of an existing custom name was accepted")
        } catch let error as PlanError {
            XCTAssertEqual(error, .invalid(["There is already a provider named Café vault."]))
        }
        // Renaming a provider to its own name is fine.
        let saved = try await store.customProviders()
        try await store.save(CustomProvider(id: saved.first?.id, name: "café vault"))
    }

    func testANamedFolderIsScannedAsItsOwnProviderWithVersioningUnknown() async throws {
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        let named = try await store.save(CustomProvider(name: "Proton", folderName: "ProtonDrive-test"))
        let choices = try await store.scanChoices()
        let roots = catalog().scanRoots(choices: choices)
        let root = try XCTUnwrap(roots.first { $0.path == proton })
        XCTAssertEqual(root.provider, named.providerID)
        XCTAssertEqual(root.providerName, "Proton")
        XCTAssertEqual(root.kind, .provider)
        XCTAssertFalse(roots.contains { $0.kind == .unrecognized && $0.path == proton })

        let id = try await store.recordScan(Scanner(roots: roots), homePath: tree.home)
        let totals = try await store.providerTotals(snapshotID: id)
        XCTAssertEqual(totals.first { $0.provider == named.providerID }?.providerName, "Proton")
        XCTAssertNil(totals.first { $0.provider == ScanRoot.unrecognizedProvider && $0.files == 1 && $0.logicalBytes == 4096 })
        let found = try await store.search(snapshotID: id, text: "file.bin", in: .name, limit: 5)
        XCTAssertEqual(found.map(\.provider), [named.providerID])
        let history = try await store.totalsHistory()
        XCTAssertEqual(history.first { $0.provider == named.providerID }?.providerName, "Proton")

        let grade = try await store.grade(snapshotID: id, facts: try ProviderFacts.bundled())
        let folder = try XCTUnwrap(grade.folders.first { $0.provider == named.providerID })
        let versioned = try XCTUnwrap(folder.checks.first { $0.kind == .versioned })
        XCTAssertEqual(versioned.status, .unknown, "never a pass without facts for the provider")
    }

    // MARK: - Excluded accounts

    func testAnExcludedAccountIsNotWalkedAndLeavesTheLatestSnapshot() async throws {
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        let first = try await store.recordScan(Scanner(roots: catalog().scanRoots()), homePath: tree.home)
        try await store.setExcluded(true, rootPath: contoso)
        let choices = try await store.scanChoices()
        XCTAssertEqual(choices.excludedRoots, [contoso])
        XCTAssertFalse(catalog().scanRoots(choices: choices).contains { $0.path == contoso })

        // The Scanner also drops it when handed every root.
        let scanner = Scanner(roots: catalog().scanRoots(), excluding: choices.excludedRoots)
        XCTAssertEqual(scanner.excludedRoots.map(\.path), [contoso])
        XCTAssertFalse(scanner.roots.contains { $0.path == contoso })
        let second = try await store.recordScan(scanner, homePath: tree.home)

        let latest = try await store.rootSummaries(snapshotID: second)
        XCTAssertFalse(latest.contains { $0.root.path == contoso })
        let found = try await store.search(snapshotID: second, text: "q3.pptx", in: .name, limit: 5)
        XCTAssertTrue(found.isEmpty, "left out of the latest snapshot")
        let earlier = try await store.search(snapshotID: first, text: "q3.pptx", in: .name, limit: 5)
        XCTAssertEqual(earlier.count, 1, "older snapshots keep their history")

        try await store.setExcluded(false, rootPath: contoso)
        let included = try await store.scanChoices()
        XCTAssertTrue(catalog().scanRoots(choices: included).contains { $0.path == contoso })
    }

    func testIncrementalRescansIgnoreAnExcludedAccount() async {
        let roots = catalog().scanRoots()
        let inside = contoso + "/Shared/readme.md"
        let result = await IncrementalScanner(roots: roots, changedPaths: [inside, contoso],
                                              excluding: [contoso]).run(snapshotID: 1)
        XCTAssertTrue(result.scope.isEmpty)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertNil(result.fullRescanReason)
    }

    func testTheWatcherDropsEventsInsideAnExcludedAccount() async throws {
        let quiet = tree.base + "/quiet"
        try FileManager.default.createDirectory(atPath: quiet, withIntermediateDirectories: true)
        let watcher = FileWatcher(paths: [quiet], latency: 0.1, quietPeriod: 0.2, excluding: [contoso])
        let events = watcher.start()
        watcher.inject([(contoso + "/Shared/readme.md", FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
                        (contoso, FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)),
                        ("/elsewhere/a.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))])
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        watcher.stop()
        // The new folder's own creation may arrive in the same batch.
        guard case .changed(let paths) = event else { return XCTFail("no batch: \(String(describing: event))") }
        XCTAssertTrue(paths.contains("/elsewhere/a.txt"))
        XCTAssertFalse(paths.contains { $0.hasPrefix(self.contoso) },
                       "the excluded account's change and its rescan request are both dropped")
    }

    // MARK: - Forgotten accounts

    func testAForgottenAccountReappearsWhenFoundAgain() async throws {
        let store = try Inventory(path: ":memory:")
        try await store.forget(rootPath: "/gone/OneDrive-Old")
        var left = try await store.reconcileForgotten(detectedRoots: ["/somewhere/else"])
        XCTAssertEqual(left, ["/gone/OneDrive-Old"], "still missing: still hidden")
        left = try await store.reconcileForgotten(detectedRoots: ["/gone/OneDrive-Old"])
        XCTAssertTrue(left.isEmpty, "found again: shown again, and the mark is gone")
        let choices = try await store.scanChoices()
        XCTAssertTrue(choices.forgottenRoots.isEmpty)
    }

    // MARK: - Cost-only plans

    func testACostOnlyPlanCountsItsCostAndNothingElse() {
        let vault = CustomProvider(id: 7, name: "Photo vault")
        let plans = [
            Subscription(provider: vault.providerID, name: "Vault 5 TB", price: 8, currency: "USD",
                         planBytes: 5_000_000_000_000),
            Subscription(provider: "dropbox", name: "Plus", price: 12, currency: "USD", planBytes: 2_000_000_000_000),
            Subscription(provider: "box", name: "Box", price: 10, currency: "USD", planBytes: 100_000_000_000),
        ]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = [
            UsagePoint(snapshotID: 1, finishedAt: start, usedBytes: ["dropbox": 1_000_000_000, "box": 1_000_000_000]),
            UsagePoint(snapshotID: 2, finishedAt: start.addingTimeInterval(40 * 86_400),
                       usedBytes: ["dropbox": 2_000_000_000, "box": 1_000_000_000]),
        ]
        let report = PlanReport.build(subscriptions: plans, usage: usage, costOnly: [vault.providerID])
        let row = try? XCTUnwrap(report.rows.first { $0.id == vault.providerID })
        XCTAssertEqual(row?.isCostOnly, true)
        XCTAssertNil(row?.usedBytes)
        XCTAssertNil(row?.headroomBytes)
        XCTAssertNil(row?.monthsToFull)
        XCTAssertNil(row?.growthPerMonth)
        XCTAssertEqual(row?.isDeadWeight, false)
        XCTAssertEqual(row?.growthNote, "Not on this Mac, so only its cost is tracked.")
        XCTAssertEqual(report.personalTotal.totals, [Money(amount: 30, currency: "USD")], "its cost counts")
        XCTAssertFalse(report.options.contains { $0.into == vault.providerID || $0.cancel == vault.providerID },
                       "no option moves data into or out of a plan with no folder")
        XCTAssertFalse(report.options.isEmpty, "the other plans still get their options")
    }
}
