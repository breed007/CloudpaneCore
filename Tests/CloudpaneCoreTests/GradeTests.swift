import XCTest
@testable import CloudpaneCore

/// Pure grader: each letter from hand-built evidence.
final class GraderTests: XCTestCase {
    private let verified = ProviderFacts(asOf: "2026-10-24", providers: [
        ProviderFact(provider: "dropbox", versioning: .keepsHistory,
                     retention: "Old versions are kept for 30 days.", sources: ["https://example.com"]),
    ])
    private let unverified = ProviderFacts(asOf: "2026-10-24", providers: [
        ProviderFact(provider: "dropbox", versioning: .toVerify),
    ])
    private let roots: [String: ScanRoot] = [
        "backup/tm": ScanRoot(id: "backup/tm", kind: .backup, provider: "backup", providerName: "Backup",
                              name: "Office Time Machine", account: nil, path: "/Volumes/TM", backupKind: .timeMachine),
        "backup/nas": ScanRoot(id: "backup/nas", kind: .backup, provider: "backup", providerName: "Backup",
                               name: "Cabin NAS", account: nil, path: "/Volumes/NAS", backupKind: .nasShare, isOffsite: true),
    ]

    private func evidence(bytes: Int64 = 1000, local: Int64, backups: [String: Int64] = [:],
                          provider: String = "dropbox", name: String = "Dropbox") -> FolderEvidence {
        FolderEvidence(rootID: "\(provider)/root", provider: provider, providerName: name, account: name,
                       folder: "Photos", files: 10, bytes: bytes, localFiles: local > 0 ? 10 : 0,
                       localBytes: local, backups: backups.mapValues { (files: 10, bytes: $0) })
    }

    private func grade(_ evidence: FolderEvidence, _ facts: ProviderFacts, paid: Set<String> = []) -> FolderGrade {
        Grader.grade(evidence, roots: roots, facts: facts, paidPlans: paid)
    }

    private func status(_ grade: FolderGrade, _ kind: GradeCheckKind) -> CheckStatus? {
        grade.checks.first { $0.kind == kind }?.status
    }

    func testA() {
        let a = grade(evidence(local: 1000, backups: ["backup/tm": 1000]), verified)
        XCTAssertEqual(a.letter, .A)
        XCTAssertEqual(a.checks.map(\.status), [.pass, .pass, .pass, .pass, .pass])
        XCTAssertEqual(a.copies.map(\.kind), [.cloud, .localSync, .backup])
        XCTAssertNil(a.fix)
        XCTAssertEqual(a.summary, "A backup holds it, and all four checks pass.")
        XCTAssertEqual(a.checks.first { $0.kind == .versioned }?.reason,
                       "Dropbox keeps file history. Old versions are kept for 30 days.", "cites the retention")
    }

    func testBWhenVersionHistoryIsUnconfirmed() {
        let b = grade(evidence(local: 1000, backups: ["backup/tm": 1000]), unverified)
        XCTAssertEqual(b.letter, .B)
        XCTAssertEqual(status(b, .versioned), .unknown, "unconfirmed is unknown, not a pass")
        XCTAssertEqual(b.summary, "A backup holds it; one check is missing: version history.")
    }

    func testBWhenOnlyTwoCopies() {
        let b = grade(evidence(local: 0, backups: ["backup/nas": 1000]), verified)
        XCTAssertEqual(b.letter, .B)
        XCTAssertEqual(status(b, .copies), .fail)
        XCTAssertEqual(b.fix, "Keep this folder downloaded on this Mac, or add a second backup location.")
        XCTAssertEqual(b.checks.first { $0.kind == .offsite }?.reason,
                       "Cabin NAS is kept off-site, and Dropbox stores a copy off the Mac.")
    }

    func testCWhenABackupHoldsItButTwoChecksAreMissing() {
        let c = grade(evidence(local: 0, backups: ["backup/tm": 1000]), unverified)
        XCTAssertEqual(c.letter, .C)
        XCTAssertEqual(c.summary, "A backup holds it, but 2 checks are missing: three copies, version history.")
    }

    func testWithoutABackupTheCeilingIsC() {
        let c = grade(evidence(local: 1000), verified)
        XCTAssertEqual(c.letter, .C)
        XCTAssertEqual(status(c, .media), .fail)
        XCTAssertEqual(c.fix, "Add a backup location such as a Time Machine disk, an external drive or a NAS share in Settings and scan again.")
    }

    func testDWithoutABackupOrHistory() {
        let d = grade(evidence(local: 1000), unverified)
        XCTAssertEqual(d.letter, .D)
        XCTAssertEqual(d.summary, "No backup holds it, and Dropbox's file history is not confirmed.")
        XCTAssertEqual(status(d, .singlePoint), .pass, "the downloaded copy is a second place")
    }

    func testFWhenNothingIsDownloadedOrBackedUp() {
        let f = grade(evidence(local: 0), verified)
        XCTAssertEqual(f.letter, .F)
        XCTAssertEqual(status(f, .singlePoint), .fail)
        XCTAssertTrue(f.fix?.hasPrefix("Keep this folder downloaded on this Mac so a backup can copy it") == true)
    }

    func testCoverageThresholdAndPartialCopies() {
        let thin = grade(evidence(local: 1000, backups: ["backup/tm": 850]), verified)
        XCTAssertEqual(thin.letter, .C, "85% in the backup is not a copy")
        XCTAssertEqual(thin.partial.map(\.name), ["Office Time Machine"])
        XCTAssertEqual(thin.partial.first?.coverage ?? 0, 0.85, accuracy: 1e-9)
        XCTAssertEqual(grade(evidence(local: 1000, backups: ["backup/tm": 900]), verified).letter, .A)
        XCTAssertEqual(grade(evidence(local: 0, backups: ["backup/tm": 10]), unverified).letter, .D,
                       "any backed-up content keeps it out of F")
    }

    func testICloudDriveKeepsNoHistorySoItCapsAtD() throws {
        let facts = try ProviderFacts.bundled()
        let d = grade(evidence(local: 1000, provider: "icloud-drive", name: "iCloud Drive"), facts)
        XCTAssertEqual(d.letter, .D)
        XCTAssertEqual(status(d, .versioned), .fail)
        XCTAssertTrue(d.checks.first { $0.kind == .versioned }?.reason.contains("last 30 days") == true)
        let b = grade(evidence(local: 1000, backups: ["backup/tm": 1000], provider: "icloud-drive", name: "iCloud Drive"), facts)
        XCTAssertEqual(b.letter, .B)
        XCTAssertEqual(b.fix, "iCloud Drive keeps no file history for this folder. A Time Machine backup keeps its own history of the folder.")
    }

    func testBoxIsVersionedOnlyWithAnActivePaidPlan() throws {
        let facts = try ProviderFacts.bundled()
        let unpaid = grade(evidence(local: 1000, provider: "box", name: "Box"), facts)
        XCTAssertEqual(unpaid.letter, .D)
        XCTAssertEqual(unpaid.checks.first { $0.kind == .versioned }?.reason,
                       "Box keeps file history only on paid plans, and no active paid Box plan is entered in Providers. Personal Pro keeps 10 versions; the free plan keeps only 1, which is no history.")
        let paid = grade(evidence(local: 1000, provider: "box", name: "Box"), facts, paid: ["box"])
        XCTAssertEqual(paid.letter, .C)
        XCTAssertEqual(status(paid, .versioned), .pass)
    }

    func testCitedProvidersCapAtCWithoutABackup() throws {
        let facts = try ProviderFacts.bundled()
        for (id, name) in [("dropbox", "Dropbox"), ("google-drive", "Google Drive"), ("onedrive", "OneDrive")] {
            XCTAssertEqual(grade(evidence(local: 1000, provider: id, name: name), facts).letter, .C, id)
        }
    }

    func testFixesNeverRecommendACloud() throws {
        let cases = [evidence(local: 0), evidence(local: 1000), evidence(local: 0, backups: ["backup/tm": 1000]),
                     evidence(local: 1000, backups: ["backup/tm": 1000])]
        for facts in [verified, unverified, try ProviderFacts.bundled()] {
            for item in cases {
                guard let fix = grade(item, facts).fix else { continue }
                for cloud in ProviderRule.defaultTable.map(\.displayName) where cloud != "Dropbox" {
                    XCTAssertFalse(fix.contains(cloud), fix)
                }
                let words = fix.lowercased().split { !$0.isLetter }
                XCTAssertFalse(words.contains("cloud") || words.contains("clouds"), fix)
                XCTAssertTrue(fix.contains("backup") || fix.contains("Time Machine"), fix)
                XCTAssertFalse(fix.contains("!"))
            }
        }
    }

    func testRollupIsAByteWeightedAverageRoundedDown() throws {
        func folder(_ letter: GradeLetter, _ bytes: Int64) -> FolderGrade {
            FolderGrade(provider: "dropbox", providerName: "Dropbox", rootID: "r", account: "a", folder: "\(letter)\(bytes)",
                        files: 1, bytes: bytes, letter: letter, summary: "", checks: [], copies: [], partial: [], fix: nil)
        }
        let mostlyGood = try XCTUnwrap(GradeRollup.make([folder(.A, 900), folder(.F, 100)]))
        XCTAssertEqual(mostlyGood.averageScore, 3.6, accuracy: 1e-9)
        XCTAssertEqual(mostlyGood.letter, .B)
        XCTAssertEqual(mostlyGood.explanation, "The byte-weighted average of 2 folders is 3.6 out of 4, which rounds down to B.")
        XCTAssertEqual(mostlyGood.distribution[.A]?.bytes, 900)
        XCTAssertEqual(mostlyGood.distribution[.F]?.folders, 1)
        XCTAssertEqual(GradeRollup.make([folder(.B, 1), folder(.B, 2), folder(.B, 3)])?.letter, .B)
        XCTAssertEqual(GradeRollup.make([folder(.A, 10), folder(.F, 990)])?.letter, .F, "a big weak folder dominates")
        XCTAssertNil(GradeRollup.make([]))
    }
}

/// The whole path: fixture trees, a scan with a backup root, and the grade from SQL.
final class GradeReportTests: XCTestCase {
    private var tree: FixtureTree!
    private let when = Date(timeIntervalSince1970: 1_780_000_000)
    private let verified = ProviderFacts(asOf: "2026-10-24", providers: ["dropbox", "google-drive"].map {
        ProviderFact(provider: $0, versioning: .keepsHistory, retention: "Kept 30 days.", sources: ["https://example.com"])
    })

    override func setUpWithError() throws { tree = try FixtureTree(empty: true) }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private func real(_ size: Int, _ path: String, at date: Date? = nil) throws {
        try tree.real(size, path)
        try tree.setModified(path, date ?? when)
    }

    private func sparse(_ size: Int64, _ path: String, at date: Date? = nil) throws {
        try tree.sparse(size, path)
        try tree.setModified(path, date ?? when)
    }

    private func gradeScan(backups: [String] = [], facts: ProviderFacts? = nil,
                           subscriptions: [Subscription] = []) async throws -> GradeReport {
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let roots = report.scanRoots(backups: backups.map {
            ScanRoot.backup(URL(fileURLWithPath: $0), label: "Desk drive", kind: .externalDrive)
        })
        let store = try Inventory(path: ":memory:")
        let id = try await store.recordScan(Scanner(roots: roots), homePath: report.homePath)
        return try await store.grade(snapshotID: id, facts: facts ?? verified, subscriptions: subscriptions)
    }

    private func letter(_ report: GradeReport, _ folder: String) -> GradeLetter? {
        report.folders.first { $0.folder == folder }?.letter
    }

    private let db = FixtureTree.dropbox
    private let gd = FixtureTree.googleDrive
    private var backupDeep: String { tree.backup + "/2026-10-24/Users/me/Library/CloudStorage/Dropbox" }

    func testLettersOnAFixtureTreeWithABackupRoot() async throws {
        try real(3000, "\(db)/Photos/a.jpg")
        try real(2000, "\(db)/Photos/b.jpg")
        try sparse(5_000_000, "\(db)/Archive/old.zip")
        try real(100, "\(db)/Mixed/x.bin")
        try sparse(1000, "\(db)/Mixed/y.bin")
        // The backup keeps its own layout, nested deep as Time Machine does, and its own case.
        try real(3000, "\(backupDeep)/Photos/a.jpg")
        try real(2000, "\(backupDeep)/Photos/B.JPG")
        let report = try await gradeScan(backups: [tree.backup])
        XCTAssertEqual(letter(report, "Photos"), .A)
        XCTAssertEqual(letter(report, "Archive"), .F)
        XCTAssertEqual(letter(report, "Mixed"), .C, "partly downloaded, versioned, no backup")
        let photos = try XCTUnwrap(report.folders.first { $0.folder == "Photos" })
        XCTAssertEqual(photos.copies.map(\.kind), [.cloud, .localSync, .backup])
        XCTAssertEqual(photos.copies.last?.name, "Desk drive")
        XCTAssertFalse(report.folders.contains { $0.provider == "backup" }, "backups are not graded")
    }

    /// Test cases s1 and s1b: another cloud holding the same placeholders changes nothing.
    func testAnotherCloudNeverRaisesTheLetter() async throws {
        for name in ["img1.jpg", "img2.jpg", "img3.jpg"] {
            try sparse(1_000_000, "\(db)/Photos/\(name)")
            try real(1_000_000, tree.backup + "/Photos/\(name)")
        }
        let alone = try await gradeScan(backups: [tree.backup])
        for name in ["img1.jpg", "img2.jpg", "img3.jpg"] {
            try sparse(1_000_000, "\(gd)/My Drive/Old/\(name)")
        }
        let withGoogle = try await gradeScan(backups: [tree.backup])
        let before = try XCTUnwrap(alone.folders.first { $0.folder == "Photos" })
        let after = try XCTUnwrap(withGoogle.folders.first { $0.folder == "Photos" })
        XCTAssertEqual(after.letter, before.letter)
        XCTAssertEqual(after.letter, .B, "cloud plus backup is two copies")
        XCTAssertEqual(after.copies.map(\.kind), [.cloud, .backup])
        XCTAssertEqual(after.checks.map(\.status), before.checks.map(\.status))
    }

    /// Test case s2: an empty file is not a downloaded copy.
    func testAnEmptyFileDoesNotKeepACloudOnlyFolderOutOfF() async throws {
        try real(0, "\(db)/Docs/empty.txt")
        for name in ["d1.pdf", "d2.pdf", "d3.pdf"] { try sparse(5_000_000, "\(db)/Docs/\(name)") }
        try real(0, "\(db)/Nothing/a.txt")
        let report = try await gradeScan()
        XCTAssertEqual(letter(report, "Docs"), .F)
        XCTAssertEqual(report.folders.first { $0.folder == "Docs" }?.files, 3, "the empty file is not counted")
        XCTAssertNil(letter(report, "Nothing"), "a folder of only empty files is not graded")
    }

    /// Test case s3: downloaded copies in another sync folder count as a copy on this Mac, and
    /// the single-point list agrees with the letter.
    func testADownloadedCopyElsewhereOnThisMacKeepsAFolderOutOfF() async throws {
        for name in ["d1.pdf", "d2.pdf", "d3.pdf"] {
            try sparse(5_000_000, "\(db)/Docs/\(name)")
            try real(5_000_000, "\(gd)/My Drive/Copy/\(name)")
        }
        let report = try await gradeScan()
        let docs = try XCTUnwrap(report.folders.first { $0.folder == "Docs" })
        XCTAssertEqual(docs.letter, .C)
        XCTAssertEqual(docs.copies.map(\.kind), [.cloud, .localSync], "no extra cloud copy")
        XCTAssertEqual(report.singlePoint.totalFiles, 0)
    }

    /// Test case s7: an unrelated file with the same name and size but another date is not a copy.
    func testMatchingNeedsTheDateWithinTwoSeconds() async throws {
        try sparse(3_000_000, "\(db)/Taxes/return.pdf")
        try real(3_000_000, tree.backup + "/unrelated/return.pdf", at: when.addingTimeInterval(86_400))
        let unrelated = try await gradeScan(backups: [tree.backup])
        XCTAssertEqual(letter(unrelated, "Taxes"), .F)
        XCTAssertEqual(unrelated.singlePoint.files.map(\.name), ["return.pdf"])

        try tree.setModified(tree.backup + "/unrelated/return.pdf", when.addingTimeInterval(1.5))
        let same = try await gradeScan(backups: [tree.backup])
        XCTAssertEqual(letter(same, "Taxes"), .B)
        XCTAssertTrue(same.singlePoint.files.isEmpty)
    }

    func testWithoutABackupNothingScoresAboveC() async throws {
        try real(3000, "\(db)/Photos/a.jpg")
        try real(3000, "\(gd)/My Drive/Photos/a.jpg")
        let report = try await gradeScan()
        XCTAssertEqual(letter(report, "Photos"), .C)
        XCTAssertFalse(report.folders.contains { $0.letter == .A || $0.letter == .B })
        XCTAssertTrue(report.backupRoots.isEmpty)
    }

    func testSinglePointListIsSortedBySizeAndPlaceholdersInOtherCloudsDoNotCount() async throws {
        try sparse(5_000_000, "\(db)/Archive/old.zip")
        try sparse(100, "\(db)/Archive/notes.txt")
        try sparse(4000, "\(db)/Shared/report.pdf")
        try sparse(4000, "\(gd)/My Drive/Docs/report.pdf")
        try real(1000, "\(db)/Mixed/x.bin")
        try sparse(1000, "\(db)/Mixed/x2.bin")
        // A placeholder inside a backup holds nothing.
        try sparse(100, tree.backup + "/Archive/notes.txt")
        let report = try await gradeScan(backups: [tree.backup])
        XCTAssertEqual(report.singlePoint.files.map(\.name), ["old.zip", "report.pdf", "report.pdf", "x2.bin", "notes.txt"])
        XCTAssertEqual(report.singlePoint.totalFiles, 5)
        XCTAssertEqual(report.singlePoint.totalBytes, 5_009_100)
        XCTAssertEqual(letter(report, "Shared"), .F)
    }

    func testBoxNeedsAPaidPlanEnteredForHistory() async throws {
        try real(3000, "\(FixtureTree.box)/Work/a.docx")
        let facts = try ProviderFacts.bundled()
        let unpaid = try await gradeScan(facts: facts)
        XCTAssertEqual(letter(unpaid, "Work"), .D)
        let paid = try await gradeScan(facts: facts, subscriptions: [
            Subscription(provider: "box", name: "Personal Pro", price: 14, currency: "USD")])
        XCTAssertEqual(letter(paid, "Work"), .C)
    }

    /// A backup made by a tool that reset dates matches nothing, but the grade says why.
    func testABackupWithoutDatesIsExplainedButNotCounted() async throws {
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try sparse(1_000_000, "\(db)/Photos/\(name)")
            try real(1_000_000, tree.backup + "/Photos/\(name)", at: when.addingTimeInterval(3 * 86_400))
        }
        let report = try await gradeScan(backups: [tree.backup])
        let photos = try XCTUnwrap(report.folders.first { $0.folder == "Photos" })
        XCTAssertEqual(photos.letter, .F, "a near match is never a copy")
        XCTAssertEqual(photos.copies.map(\.kind), [.cloud])
        XCTAssertTrue(photos.summary.hasSuffix(
            "Most files in Desk drive match by name and size but not by date, so they were not counted. The backup may have been made without keeping dates."),
                      photos.summary)

        // With the dates kept, the same backup counts and there is nothing to explain.
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try tree.setModified(tree.backup + "/Photos/\(name)", when) }
        let kept = try await gradeScan(backups: [tree.backup])
        let fixed = try XCTUnwrap(kept.folders.first { $0.folder == "Photos" })
        XCTAssertEqual(fixed.letter, .B)
        XCTAssertFalse(fixed.summary.contains("not by date"))
    }

    /// Two quick plan saves: the newer grade wins, and the older run's result is dropped
    /// even though it started first.
    func testTwoQuickSavesEndWithTheNewestGrade() async throws {
        try real(3000, "\(FixtureTree.box)/Work/a.docx")
        let report = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect()
        let store = try Inventory(path: tree.base + "/plans.sqlite")
        let id = try await store.recordScan(Scanner(roots: report.scanRoots()), homePath: report.homePath)
        let facts = try ProviderFacts.bundled()
        let latest = LatestOnly<GradeReport>()

        // First save: no paid Box plan. Its grade is slow, as on a big library: it has started
        // (and registered) before the second save, and is still running when that one starts.
        let free = try await store.save(Subscription(provider: "box", name: "Free", price: 0, currency: "USD"))
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let older = Task {
            try await latest.run {
                signal.yield()
                try await Task.sleep(for: .seconds(60))
                return try await store.grade(snapshotID: id, facts: facts, subscriptions: [free])
            }
        }
        for await _ in started { break }
        // Second save, moments later: a paid plan.
        var paid = free
        paid.price = 14
        try await store.save(paid)
        let newer = try await latest.run {
            try await store.grade(snapshotID: id, facts: facts, subscriptions: try await store.subscriptions())
        }
        let olderResult = try await older.value
        XCTAssertNil(olderResult, "the superseded grade is never published")
        XCTAssertEqual(newer?.folders.first { $0.folder == "Work" }?.letter, .C, "paid Box counts as versioned")
    }

    func testGradingRefusesAnIncompleteSnapshot() async throws {
        let store = try Inventory(path: ":memory:")
        let id = try await store.beginSnapshot(homePath: tree.home, placeholderRule: "test")
        do {
            _ = try await store.grade(snapshotID: id, facts: verified)
            XCTFail("an incomplete scan cannot be graded")
        } catch InventoryError.incompleteSnapshot {}
    }
}

/// Grading must stay fast on a large library. The plan check catches a full scan of the key
/// table returning; the timing catches anything else that goes quadratic.
final class GradePerformanceTests: XCTestCase {
    private func record(_ id: Int64, _ index: Int, provider: String, root: String, placeholder: Bool,
                        modified: Date) -> FileRecord {
        let name = "file_\(index % 1000)_with_a_long_name.dat"
        let folder = provider == "backup" ? "copy/folder_\(index / 1000)" : "folder_\(index / 1000)"
        return FileRecord(snapshotID: id, path: "/\(root)/\(folder)/\(name)", rootID: root, provider: provider,
                          relativePath: "\(folder)/\(name)", name: name, topLevelFolder: folder,
                          facts: FileFacts(logicalSize: 1000, allocatedSize: placeholder ? 0 : 4096),
                          modified: modified, isPackage: false, isPlaceholder: placeholder, contentType: nil,
                          category: .other)
    }

    /// 50,000 Dropbox placeholders, every one matched in a backup root, with names repeating
    /// as in the test case (1,000 names, dates spread over 20 seconds).
    /// extraBackups adds that many more backup roots of 1,000 files each, as in the
    /// 21-backup database, which is where per-backup passes got slow.
    private func largeInventory(path: String = ":memory:", extraBackups: Int = 0) async throws -> (Inventory, Int64) {
        let store = try Inventory(path: path)
        let id = try await store.beginSnapshot(homePath: "/h", placeholderRule: "test")
        let count = 50_000
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var batch: [FileRecord] = []
        for index in 0..<count {
            let date = base.addingTimeInterval(Double(index % 20_000) / 1000)
            batch.append(record(id, index, provider: "dropbox", root: "dropbox/Dropbox", placeholder: true, modified: date))
            batch.append(record(id, index, provider: "backup", root: "backup/b", placeholder: false, modified: date))
            if batch.count >= 10_000 {
                try await store.insert(batch)
                batch.removeAll()
            }
        }
        var extraRoots: [ScanRoot] = []
        for extra in 0..<extraBackups {
            let rootID = "backup/extra\(extra)"
            for index in 0..<1000 {
                let date = base.addingTimeInterval(Double((index * 37) % 20_000) / 1000)
                batch.append(record(id, index * 50 + extra, provider: "backup", root: rootID, placeholder: false, modified: date))
            }
            extraRoots.append(ScanRoot(id: rootID, kind: .backup, provider: "backup", providerName: "Backup",
                                       name: "Extra \(extra)", account: nil, path: "/" + rootID, backupKind: .externalDrive))
        }
        try await store.insert(batch)
        for (position, root) in ([
            ScanRoot(id: "dropbox/Dropbox", kind: .provider, provider: "dropbox", providerName: "Dropbox",
                     name: "Dropbox", account: nil, path: "/dropbox/Dropbox"),
            ScanRoot(id: "backup/b", kind: .backup, provider: "backup", providerName: "Backup", name: "Disk",
                     account: nil, path: "/backup/b", backupKind: .externalDrive),
        ] + extraRoots).enumerated() {
            try await store.insert(RootSummary(root: root), snapshotID: id, position: position)
        }
        try await store.finishSnapshot(id, status: .complete)
        return (store, id)
    }

    func testNoGradingQueryScansTheKeyTable() async throws {
        let (store, id) = try await largeInventory()
        let plans = try await store.gradeQueryPlans(snapshotID: id)
        XCTAssertEqual(Set(plans.keys), ["pass", "overflow", "singlePoint"])
        for (name, lines) in plans {
            XCTAssertTrue(lines.contains { $0.contains("SEARCH k") && $0.contains("INDEX grade_keys") },
                          "\(name) must seek the key index: \(lines)")
            XCTAssertFalse(lines.contains { $0.contains("SCAN k") || $0.contains("SCAN n") },
                           "\(name) scans a key table: \(lines)")
        }
        XCTAssertTrue(plans["pass"]?.contains { $0.contains("COVERING INDEX grade_keys_any") } == true,
                      "the per-file probe never touches the key table itself: \(plans["pass"] ?? [])")
    }

    /// On disk, grading uses its own connection, so a search started meanwhile is answered
    /// at once rather than after the grade.
    func testGradingOnDiskDoesNotHoldUpOtherReads() async throws {
        let tree = try FixtureTree(empty: true)
        defer { tree.remove() }
        let (store, id) = try await largeInventory(path: tree.base + "/large.sqlite")
        let facts = try ProviderFacts.bundled()
        let clock = ContinuousClock()
        let start = clock.now
        async let graded = store.grade(snapshotID: id, facts: facts)
        try await Task.sleep(for: .milliseconds(20))
        let hits = try await store.search(snapshotID: id, text: "file_7_with", limit: 10)
        let searchDone = clock.now - start
        let report = try await graded
        let gradeDone = clock.now - start
        XCTAssertEqual(hits.count, 10)
        XCTAssertEqual(report.folders.count, 50)
        XCTAssertTrue(report.folders.allSatisfy { $0.letter == .B }, "the reader sees the same data")
        XCTAssertLessThan(searchDone, gradeDone, "search waited for grading: \(searchDone) vs \(gradeDone)")
    }

    /// Canceling a grade stops it mid-query instead of finishing the work.
    /// Canceling after the grade tables are built stops the work before its passes: the
    /// caller gets CancellationError, never a report. The seam holds the grading thread until
    /// the test has canceled, so nothing depends on timing.
    func testCancelingAGradeStopsIt() async throws {
        let tree = try FixtureTree(empty: true)
        defer { tree.remove() }
        let (store, id) = try await largeInventory(path: tree.base + "/cancel.sqlite")
        let facts = try ProviderFacts.bundled()
        let (built, signal) = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await store.grade(snapshotID: id, facts: facts, subscriptions: [], singlePointLimit: 500) {
                signal.yield()
                release.wait()
            }
        }
        for await _ in built { break }
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("a canceled grade must not return a report")
        } catch is CancellationError {}
    }

    /// Ordering is explicit: each slow run signals that it has started, which means it has
    /// registered, before the newer run starts.
    func testLatestOnlyKeepsTheNewestResult() async throws {
        let latest = LatestOnly<String>()
        let (slowStarted, slowSignal) = AsyncStream.makeStream(of: Void.self)
        let slow = Task {
            try await latest.run {
                slowSignal.yield()
                try await Task.sleep(for: .seconds(60))
                return "old"
            }
        }
        for await _ in slowStarted { break }
        let fast = try await latest.run { "new" }
        let slowValue = try await slow.value
        XCTAssertEqual(fast, "new")
        XCTAssertNil(slowValue, "canceled by the newer run")

        // A run that ignores cancellation and finishes after a newer one still returns nil.
        let gate = Gate()
        let (stubbornStarted, stubbornSignal) = AsyncStream.makeStream(of: Void.self)
        let stubborn = Task {
            try await latest.run {
                stubbornSignal.yield()
                await gate.wait()
                return "stale"
            }
        }
        for await _ in stubbornStarted { break }
        let newest = try await latest.run { "newest" }
        await gate.open()
        let stubbornValue = try await stubborn.value
        XCTAssertEqual(newest, "newest")
        XCTAssertNil(stubbornValue)
    }

    func testGradingALargeLibraryIsFast() async throws {
        let (store, id) = try await largeInventory(extraBackups: 20)
        let facts = try ProviderFacts.bundled()
        let start = Date()
        let report = try await store.grade(snapshotID: id, facts: facts)
        let elapsed = Date().timeIntervalSince(start)
        print("grade on 120,000 files and 21 backups:", String(format: "%.2f s", elapsed))
        XCTAssertEqual(report.folders.count, 50)
        XCTAssertTrue(report.folders.allSatisfy { $0.letter == .B }, "every folder is held by the backup")
        XCTAssertEqual(report.singlePoint.totalFiles, 0)
        XCTAssertEqual(report.backupRoots.count, 21)
        // One pass per backup root was the M4 regression: 14 s on a 21-backup test database.
        XCTAssertLessThan(elapsed, 3, "grading 120,000 files across 21 backups took \(elapsed) s")
    }
}

/// Holds callers until opened. Ignores cancellation on purpose.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
