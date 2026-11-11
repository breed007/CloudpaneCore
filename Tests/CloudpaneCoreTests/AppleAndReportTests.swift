import Darwin
import XCTest
@testable import CloudpaneCore

/// The iCloud figures a scan cannot read (Photos estimate, entered total), and the report.
final class AppleUsageTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws { tree = try FixtureTree(empty: true) }
    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private var library: String { tree.path("Pictures/Photos Library.photoslibrary") }

    func testPhotosEstimateSumsMetadataInsideThePackage() throws {
        try tree.real(3_000, library + "/originals/A/IMG_0001.heic")
        try tree.real(2_000, library + "/resources/derivatives/thumb.jpeg")
        try tree.real(500, library + "/database/Photos.sqlite")
        try tree.real(100, library + "/.hidden-state")
        try tree.hide(library + "/.hidden-state")
        try tree.hardLink(library + "/originals/A/IMG_0001.heic", library + "/originals/A/link.heic")
        try tree.symlink(to: "/etc/hosts", at: library + "/external")
        try tree.sparse(1_000_000, library + "/originals/B/evicted.mov")

        let estimate = try PhotosLibrary.estimate(at: URL(fileURLWithPath: library),
                                                  now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(estimate.fileCount, 5, "the hard link counts once; the symlink not at all")
        XCTAssertEqual(estimate.logicalBytes, 3_000 + 2_000 + 500 + 100 + 1_000_000)
        XCTAssertLessThan(estimate.allocatedBytes, estimate.logicalBytes, "the sparse file allocates almost nothing")
        XCTAssertEqual(estimate.unreadableCount, 0)
        XCTAssertEqual(estimate.measuredAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testPhotosEstimateRefusesWhatIsNotALibrary() throws {
        try tree.folder("Pictures/Holiday")
        XCTAssertThrowsError(try PhotosLibrary.estimate(at: URL(fileURLWithPath: tree.path("Pictures/Holiday")))) {
            XCTAssertEqual($0 as? PhotosLibraryError, .notAPhotosLibrary)
        }
        try tree.real(10, "Pictures/Fake.photoslibrary")
        XCTAssertThrowsError(try PhotosLibrary.estimate(at: URL(fileURLWithPath: tree.path("Pictures/Fake.photoslibrary")))) {
            XCTAssertEqual($0 as? PhotosLibraryError, .notAPhotosLibrary, "a file with the extension is not a package")
        }
        XCTAssertThrowsError(try PhotosLibrary.estimate(at: URL(fileURLWithPath: library))) {
            XCTAssertEqual($0 as? PhotosLibraryError, .notFound)
        }
    }

    /// Cloudpane cannot work around a refusal, so a package it may not list is
    /// reported as denied, not measured as empty. A mode-000 folder stands in for the
    /// refusal; whether macOS's privacy protection for Photos refuses a user-selected
    /// library is not verified here.
    func testAPackageThatCannotBeListedIsReportedAsDenied() throws {
        try tree.real(3_000, library + "/originals/IMG_0001.heic")
        try tree.lock(library)
        XCTAssertThrowsError(try PhotosLibrary.estimate(at: URL(fileURLWithPath: library))) {
            XCTAssertEqual($0 as? PhotosLibraryError, .accessDenied)
        }
    }

    func testAnUnreadableFolderInsideIsCountedNotFatal() throws {
        try tree.real(3_000, library + "/originals/IMG_0001.heic")
        try tree.real(4_000, library + "/private/locked/secret.bin")
        try tree.lock(library + "/private/locked")
        let estimate = try PhotosLibrary.estimate(at: URL(fileURLWithPath: library))
        XCTAssertEqual(estimate.logicalBytes, 3_000)
        XCTAssertEqual(estimate.unreadableCount, 1)
    }

    func testCancelingStopsTheEstimate() throws {
        try tree.real(3_000, library + "/originals/IMG_0001.heic")
        XCTAssertThrowsError(try PhotosLibrary.estimate(at: URL(fileURLWithPath: library), isCanceled: { true })) {
            XCTAssertEqual($0 as? PhotosLibraryError, .canceled)
        }
    }

    func testEnteredTotalAndPhotosAreStored() async throws {
        let store = try Inventory(path: ":memory:")
        let empty = try await store.reportedUsage()
        XCTAssertTrue(empty.isEmpty)

        let entered = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.setReportedUsage(ReportedUsage(provider: "icloud-drive", bytes: 150_000_000_000, enteredAt: entered))
        try await store.setReportedUsage(ReportedUsage(provider: "icloud-drive", bytes: 160_000_000_000, enteredAt: entered))
        let one = try await store.reportedUsage()
        XCTAssertEqual(one["icloud-drive"]?.bytes, 160_000_000_000, "a second total replaces the first")
        do {
            try await store.setReportedUsage(ReportedUsage(provider: "icloud-drive", bytes: -1))
            XCTFail("a negative total was saved")
        } catch let error as PlanError {
            XCTAssertEqual(error, .invalid(["The total cannot be negative."]))
        }
        try await store.clearReportedUsage(provider: "icloud-drive")
        let cleared = try await store.reportedUsage()
        XCTAssertTrue(cleared.isEmpty)

        let estimate = PhotosLibraryEstimate(logicalBytes: 9, allocatedBytes: 8, fileCount: 7, datalessCount: 6,
                                             unreadableCount: 5, measuredAt: entered)
        try await store.recordPhotosEstimate(estimate)
        let none = try await store.photosLibrary()
        XCTAssertNil(none, "an estimate without a chosen library is not stored")

        try await store.setPhotosLibrary(path: "/p/A.photoslibrary", bookmark: Data([1]))
        try await store.recordPhotosEstimate(estimate)
        try await store.setPhotosLibrary(path: "/p/A.photoslibrary", bookmark: Data([2]))
        let same = try await store.photosLibrary()
        XCTAssertEqual(same?.estimate, estimate, "choosing the same library again keeps its estimate")
        XCTAssertEqual(same?.bookmark, Data([2]))
        try await store.setPhotosLibrary(path: "/p/B.photoslibrary", bookmark: Data([3]))
        let other = try await store.photosLibrary()
        XCTAssertEqual(other?.path, "/p/B.photoslibrary")
        XCTAssertNil(other?.estimate, "another library starts without an estimate")
        try await store.clearPhotosLibrary()
        let gone = try await store.photosLibrary()
        XCTAssertNil(gone)
    }

    func testVersion5DatabaseGainsTheNewTables() async throws {
        let path = tree.base + "/v5.sqlite"
        let db = try SQLiteConnection(path: path)
        try db.execute(Inventory.schemaV2 + Inventory.migrationV3 + Inventory.migrationV4 + Inventory.migrationV5
                       + "PRAGMA user_version = 5;")
        try db.execute("INSERT INTO snapshots (id, started_at, finished_at, status, home_path, placeholder_rule) VALUES (1, 1790000000, 1790000060, 'complete', '/h', 'r');")
        let store = try Inventory(path: path)
        let version = try await store.schemaVersion()
        XCTAssertEqual(version, 9)
        let snapshots = try await store.snapshots()
        XCTAssertEqual(snapshots.map(\.id), [1])
        try await store.setReportedUsage(ReportedUsage(provider: "icloud-drive", bytes: 1))
        try await store.setPhotosLibrary(path: "/p/A.photoslibrary", bookmark: Data([1]))
    }

    // MARK: - Plan math

    private func usage(_ bytes: Int64, at seconds: TimeInterval) -> UsagePoint {
        UsagePoint(snapshotID: Int64(seconds), finishedAt: Date(timeIntervalSince1970: seconds),
                   usedBytes: ["icloud-drive": bytes])
    }

    private let plan = Subscription(provider: "icloud-drive", name: "iCloud+ 200 GB", price: Decimal(string: "2.99")!,
                                    currency: "USD", planBytes: 200_000_000_000)

    func testTheEnteredTotalReplacesTheScannedFigure() {
        let points = [usage(5_000_000_000, at: 1_800_000_000), usage(6_000_000_000, at: 1_800_000_000 + 30 * 86_400)]
        let scanned = PlanReport.build(subscriptions: [plan], usage: points)
        XCTAssertEqual(scanned.rows.first?.usedBytes, 6_000_000_000)
        XCTAssertNil(scanned.rows.first?.reportedTotal)
        XCTAssertNotNil(scanned.rows.first?.growthPerMonth)

        let total = ReportedUsage(provider: "icloud-drive", bytes: 150_000_000_000)
        let entered = PlanReport.build(subscriptions: [plan], usage: points, reported: ["icloud-drive": total])
        let row = entered.rows.first
        XCTAssertEqual(row?.usedBytes, 150_000_000_000)
        XCTAssertEqual(row?.headroomBytes, 50_000_000_000)
        XCTAssertEqual(row?.fractionUsed ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(row?.reportedTotal, total)
        XCTAssertNil(row?.growthPerMonth, "a typed-in figure against a scanned one is not growth")
        XCTAssertEqual(row?.growthNote, "Growth is not measured while the plan uses the total you entered.")
    }

    func testAnEnteredTotalClearsDeadWeight() {
        let points = [usage(1_000_000_000, at: 1_800_000_000), usage(1_000_000_000, at: 1_800_000_000 + 2 * 86_400)]
        XCTAssertEqual(PlanReport.build(subscriptions: [plan], usage: points).rows.first?.isDeadWeight, true)
        let total = ReportedUsage(provider: "icloud-drive", bytes: 150_000_000_000)
        XCTAssertEqual(PlanReport.build(subscriptions: [plan], usage: points, reported: ["icloud-drive": total])
                           .rows.first?.isDeadWeight, false, "the whole account is 75% used")
        let small = ReportedUsage(provider: "icloud-drive", bytes: 2_000_000_000)
        XCTAssertEqual(PlanReport.build(subscriptions: [plan], usage: points, reported: ["icloud-drive": small])
                           .rows.first?.isDeadWeight, true)
    }

    func testICloudBreakdown() {
        let photos = PhotosLibraryEstimate(logicalBytes: 40_000_000_000, allocatedBytes: 10_000_000_000, fileCount: 1,
                                           datalessCount: 0, unreadableCount: 0, measuredAt: Date())
        let none = ICloudUsage(driveBytes: 6_000_000_000, photos: photos, reportedTotal: nil)
        XCTAssertEqual(none.planBytes, 6_000_000_000, "the estimate never joins the plan math")
        XCTAssertNil(none.otherBytes)
        let total = ICloudUsage(driveBytes: 6_000_000_000, photos: photos,
                                reportedTotal: ReportedUsage(provider: "icloud-drive", bytes: 150_000_000_000))
        XCTAssertEqual(total.planBytes, 150_000_000_000)
        XCTAssertEqual(total.otherBytes, 104_000_000_000)
        let under = ICloudUsage(driveBytes: 6_000_000_000, photos: photos,
                                reportedTotal: ReportedUsage(provider: "icloud-drive", bytes: 1_000))
        XCTAssertEqual(under.otherBytes, 0, "an estimate larger than the total never goes negative")
    }

    // MARK: - Writing a finished file

    func testWriteNewFileNeverReplaces() throws {
        let target = URL(fileURLWithPath: tree.base + "/Report.pdf")
        try writeNewFile(Data("first".utf8), to: target)
        XCTAssertThrowsError(try writeNewFile(Data("second".utf8), to: target)) {
            XCTAssertEqual($0 as? ExportError, .destinationExists(target.path))
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "first")
    }
}

final class ReportTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws { tree = try FixtureTree(empty: true) }
    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    /// A Google Drive account named by its email, a folder and a file with telling names,
    /// and a labeled backup that holds part of it.
    private func buildInput() async throws -> (ReportInput, [String]) {
        let account = "GoogleDrive-private.person@example.com"
        let drive = "Library/CloudStorage/\(account)/My Drive"
        try tree.real(4_000, "\(drive)/Taxes 2025/secret-plan.pdf")
        try tree.real(3_000, "\(drive)/Taxes 2025/receipt-kept.pdf")
        try tree.sparse(2_000_000, "\(drive)/Medical/scan-only-in-cloud.pdf")
        // The backup copies lost their dates, so the grade explains them by the backup's label.
        try tree.real(4_000, tree.backup + "/Office NAS/Taxes 2025/secret-plan.pdf")
        try tree.real(3_000, tree.backup + "/Office NAS/Taxes 2025/receipt-kept.pdf")
        try tree.setModified(tree.backup + "/Office NAS/Taxes 2025/secret-plan.pdf", Date(timeIntervalSince1970: 1_700_000_000))
        try tree.setModified(tree.backup + "/Office NAS/Taxes 2025/receipt-kept.pdf", Date(timeIntervalSince1970: 1_700_000_000))
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let backup = ScanRoot.backup(URL(fileURLWithPath: tree.backup + "/Office NAS"), label: "Office NAS",
                                     kind: .nasShare)
        let id = try await store.recordScan(Scanner(roots: report.scanRoots(backups: [backup])), homePath: report.homePath)
        let snapshot = try await store.snapshot(id)
        let totals = try await store.providerTotals(snapshotID: id)
        let roots = try await store.rootSummaries(snapshotID: id)
        let plans = PlanReport.build(subscriptions: [
            Subscription(provider: "google-drive", name: "Google One 2 TB", price: 10, currency: "USD",
                         planBytes: 2_000_000_000_000),
        ], usage: try await store.usageHistory())
        let grade = try await store.grade(snapshotID: id, facts: try ProviderFacts.bundled())
        let duplicates = try await store.duplicates(snapshotID: id)
        let history = try await store.totalsHistory()
        let input = ReportInput(generatedAt: Date(timeIntervalSince1970: 1_800_000_000), snapshot: snapshot,
                                catalog: report, totals: totals, roots: roots, plans: plans,
                                iCloud: ICloudUsage(driveBytes: nil, photos: nil, reportedTotal: nil),
                                grade: grade, duplicates: duplicates, history: history)
        let secrets = [tree.home, tree.base, "private.person", "example.com", "Taxes 2025", "Medical",
                       "secret-plan", "receipt-kept", "scan-only-in-cloud", "Office NAS", "My Drive"]
        return (input, secrets)
    }

    func testHiddenPathsLeaveNoNameInTheReport() async throws {
        let (input, secrets) = try await buildInput()
        let hidden = ReportDocument.build(input, options: ReportOptions(hidePaths: true)).plainText
        for secret in secrets {
            XCTAssertFalse(hidden.contains(secret), "the shared report contains \(secret)")
        }
        XCTAssertTrue(hidden.contains("Google Drive folder 1"))
        XCTAssertTrue(hidden.contains("Google One 2 TB"))
        XCTAssertTrue(hidden.contains("Plan names you typed are included."))

        // The same input with paths shown must contain them, or the check above proves nothing.
        let shown = ReportDocument.build(input, options: ReportOptions(hidePaths: false)).plainText
        for secret in ["private.person@example.com", "Taxes 2025", "scan-only-in-cloud.pdf", "Office NAS"] {
            XCTAssertTrue(shown.contains(secret), "the full report is missing \(secret)")
        }
        XCTAssertFalse(shown.contains(tree.home + "/"), "paths are shown from ~, never with the home folder")
    }

    /// Folders are listed largest first, numerically, and capped per provider.
    func testTheFolderTableIsSortedBySizeAndCapped() {
        let folders = (1...120).map { index in
            FolderGrade(provider: "dropbox", providerName: "Dropbox", rootID: "dropbox/Dropbox", account: "",
                        folder: "\(index)", files: 1, bytes: Int64(index) * 1_000, letter: .D,
                        summary: "No backup holds it.", checks: [], copies: [], partial: [], fix: nil)
        }
        let grade = GradeReport(snapshotID: 1, folders: folders, overall: GradeRollup.make(folders),
                                byProvider: ["dropbox": GradeRollup.make(folders)!],
                                singlePoint: SinglePointList(files: [], totalFiles: 0, totalBytes: 0), backupRoots: [])
        let section = ReportDocument.grade(ReportInput(grade: grade), ReportOptions(hidePaths: false), ReportFormat())
        guard case .table(let headers, let rows) = section.blocks.first(where: {
            if case .table(let headers, _) = $0 { return headers.first == "Folder" }
            return false
        }) else { return XCTFail("no folder table") }
        XCTAssertEqual(headers, ["Folder", "Size", "Grade", "Why", "To improve it"])
        XCTAssertEqual(rows.count, ReportDocument.foldersPerProviderLimit)
        XCTAssertEqual(rows.prefix(3).map(\.first), ["Dropbox: 120", "Dropbox: 119", "Dropbox: 118"],
                       "largest first, compared as sizes, not as text")
        XCTAssertEqual(rows.last?.first, "Dropbox: 71")
        XCTAssertTrue(section.blocks.contains(.note("And 70 more Dropbox folders, not listed here. Cloudpane shows every folder.")))
    }

    func testCountsAreSingularForOne() {
        let format = ReportFormat(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(format.counted(1, "file"), "1 file")
        XCTAssertEqual(format.counted(0, "file"), "0 files")
        XCTAssertEqual(format.counted(1_200, "folder"), "1,200 folders")
        XCTAssertEqual(format.files(1), "1 file")
    }

    func testTheReportCoversEverySection() async throws {
        let (input, _) = try await buildInput()
        let document = ReportDocument.build(input)
        XCTAssertEqual(document.sections.map(\.title),
                       ["Overview", "Plans", "Backup grade", "Single points of failure", "Duplicates", "History",
                        "About this report"])
        let text = document.plainText
        XCTAssertTrue(text.contains("Overall: "))
        XCTAssertTrue(text.contains("Device backups | Not available in this build"))
        XCTAssertTrue(text.contains(
            "Mail | Not available in this build | Reading it needs Full Disk Access, which Cloudpane does not request."))
        XCTAssertFalse(text.contains("App Store"))
        XCTAssertTrue(text.contains("Personal total: "))
        XCTAssertTrue(text.contains("Not installed on this Mac: iCloud Drive, Dropbox, OneDrive, Box."))
    }
}

/// The state a first-time user with only Google Drive is in: GoogleDrive-<email> exists,
/// every other provider is missing, and the inventory is empty. Then the first scan, of a
/// Google Drive with nothing downloaded.
final class GoogleDriveOnlyTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws {
        tree = try FixtureTree(empty: true)
        try tree.folder("Library/CloudStorage/GoogleDrive-only.user@example.com/My Drive")
        try tree.folder("Library/CloudStorage/GoogleDrive-only.user@example.com/Shared drives")
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    func testDetectionShowsOnlyGoogleDrive() {
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let states = Dictionary(uniqueKeysWithValues: report.providers.map { ($0.rule.id, $0.state) })
        XCTAssertEqual(states, ["google-drive": .installed, "icloud-drive": .missing, "dropbox": .missing,
                                "onedrive": .missing, "box": .missing])
        XCTAssertEqual(report.providers.first { $0.rule.id == "google-drive" }?.roots.map(\.account),
                       ["only.user@example.com"])
        XCTAssertTrue(report.unrecognized.isEmpty)
        XCTAssertEqual(report.scanRoots().map(\.provider), ["google-drive"])
    }

    func testAnEmptyInventoryHasNothingToShowAndNothingFails() async throws {
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        let snapshots = try await store.snapshots()
        let usage = try await store.usageHistory()
        let history = try await store.totalsHistory()
        let plans = try await store.subscriptions()
        let iCloud = try await store.iCloudUsage()
        let photos = try await store.photosLibrary()
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(usage.isEmpty)
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(plans.isEmpty)
        XCTAssertNil(photos)
        XCTAssertEqual(iCloud, ICloudUsage(driveBytes: nil, photos: nil, reportedTotal: nil))

        let report = PlanReport.build(subscriptions: [], usage: usage)
        XCTAssertTrue(report.rows.isEmpty)
        XCTAssertTrue(report.personalTotal.isEmpty)
        XCTAssertTrue(report.options.isEmpty)

        let catalog = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let document = ReportDocument.build(ReportInput(catalog: catalog, plans: report, iCloud: iCloud))
        let text = document.plainText
        XCTAssertTrue(text.contains("No complete scan yet."))
        XCTAssertTrue(text.contains("Run a scan to see how much is stored with each provider."))
        XCTAssertTrue(text.contains("The grade appears after a complete scan"))
        XCTAssertTrue(text.contains("History appears after the first complete scan."))
        XCTAssertFalse(text.contains("only.user"), "the account stays out of a shared report")
    }

    func testTheFirstScanOfAnEmptyGoogleDrive() async throws {
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        let catalog = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let id = try await store.recordScan(Scanner(roots: catalog.scanRoots()), homePath: catalog.homePath)
        let snapshot = try await store.snapshot(id)
        XCTAssertEqual(snapshot?.status, .complete)
        let totals = try await store.providerTotals(snapshotID: id)
        XCTAssertTrue(totals.isEmpty, "no files means no provider row, not a crash")
        let roots = try await store.rootSummaries(snapshotID: id)
        XCTAssertEqual(roots.map(\.root.provider), ["google-drive"])
        XCTAssertEqual(roots.first?.files, 0)

        let grade = try await store.grade(snapshotID: id, facts: try ProviderFacts.bundled())
        XCTAssertNil(grade.overall)
        XCTAssertEqual(grade.singlePoint.totalFiles, 0)
        let duplicates = try await store.duplicates(snapshotID: id)
        XCTAssertEqual(duplicates.totalGroups, 0)
        let usage = try await store.usageHistory()
        let plan = Subscription(provider: "google-drive", name: "Google One 100 GB", price: Decimal(string: "1.99")!,
                                currency: "USD", planBytes: 100_000_000_000)
        let plans = PlanReport.build(subscriptions: [plan], usage: usage)
        XCTAssertEqual(plans.rows.first?.growthNote, "Growth appears after two complete scans.")

        let document = ReportDocument.build(ReportInput(
            snapshot: snapshot, catalog: catalog, totals: totals, roots: roots, plans: plans, grade: grade,
            duplicates: duplicates, history: try await store.totalsHistory()))
        let text = document.plainText
        XCTAssertTrue(text.contains("The last scan found no files in any cloud storage folder."))
        XCTAssertTrue(text.contains("No duplicates were found."))
        XCTAssertTrue(text.contains("Google One 100 GB"))
    }

    func testTheFirstScanOfAGoogleDriveWithOnlyPlaceholders() async throws {
        try tree.sparse(5_000_000, "Library/CloudStorage/GoogleDrive-only.user@example.com/My Drive/Work/deck.key")
        let store = try Inventory(path: tree.base + "/inventory.sqlite")
        let catalog = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let id = try await store.recordScan(Scanner(roots: catalog.scanRoots()), homePath: catalog.homePath)
        let totals = try await store.providerTotals(snapshotID: id)
        XCTAssertEqual(totals.map(\.provider), ["google-drive"])
        XCTAssertEqual(totals.first?.placeholderBytes, 5_000_000)
        let grade = try await store.grade(snapshotID: id, facts: try ProviderFacts.bundled())
        XCTAssertEqual(grade.overall?.letter, .F, "nothing downloaded and no backup")
        XCTAssertEqual(grade.singlePoint.totalFiles, 1)
    }
}
