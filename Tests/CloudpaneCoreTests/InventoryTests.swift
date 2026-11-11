import XCTest
@testable import CloudpaneCore

final class InventoryTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws {
        tree = try FixtureTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    func testSearchByNameAndPath() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let store = run.inventory
        let id = run.snapshotID

        let report = try await store.search(snapshotID: id, text: "report")
        XCTAssertEqual(report.map(\.name), ["report.pdf"])
        XCTAssertEqual(report.first?.provider, "icloud-drive")
        XCTAssertEqual(report.first?.rootID, "icloud-drive/com~apple~CloudDocs")
        XCTAssertEqual(report.first?.relativePath, "Documents/report.pdf")
        XCTAssertEqual(report.first?.topLevelFolder, "Documents")
        XCTAssertEqual(report.first?.contentType, "com.adobe.pdf")
        XCTAssertEqual(report.first?.category, .document)
        XCTAssertNotNil(report.first?.modified)

        let budget = try await store.search(snapshotID: id, text: "BUDGET")
        XCTAssertEqual(budget.map(\.name), ["Budget.xlsx"], "case-insensitive for ASCII")

        // % and _ are literal, not wildcards.
        let literal = try await store.search(snapshotID: id, text: "100%_")
        XCTAssertEqual(literal.map(\.name), ["100%_done.txt"])
        let underscore = try await store.search(snapshotID: id, text: "_")
        XCTAssertEqual(underscore.map(\.name), ["100%_done.txt"])

        // A folder name matches by path only.
        let byName = try await store.search(snapshotID: id, text: "Projects")
        XCTAssertTrue(byName.isEmpty)
        let byPath = try await store.search(snapshotID: id, text: "Projects", in: .path)
        XCTAssertEqual(byPath.map(\.name), ["archive.zip", "plan.docx"])

        let odd = try await store.search(snapshotID: id, text: "line\nbreak")
        XCTAssertEqual(odd.count, 1)
        let limited = try await store.search(snapshotID: id, text: ".", limit: 3)
        XCTAssertEqual(limited.count, 3)
        let none = try await store.search(snapshotID: id, text: "no such file")
        XCTAssertTrue(none.isEmpty)
    }

    func testDiffBetweenTwoSnapshots() async throws {
        let store = try Inventory(path: ":memory:")
        let first = try await ScanRun.run(home: tree.home, inventory: store)

        let icloud = FixtureTree.iCloud
        try tree.real(50, "\(icloud)/Documents/new.txt")
        try FileManager.default.removeItem(atPath: tree.path("\(icloud)/Documents/notes.txt"))
        try tree.real(25_000, "\(FixtureTree.oneDrivePersonal)/Documents/cv.docx")
        // Materialize a placeholder: same size, now with real blocks.
        let plan = "\(FixtureTree.googleDrive)/My Drive/Projects/plan.docx"
        let planDate = try FileManager.default.attributesOfItem(atPath: tree.path(plan))[.modificationDate] as? Date
        try FileManager.default.removeItem(atPath: tree.path(plan))
        try tree.real(1_500_000, plan)
        try FileManager.default.setAttributes([.modificationDate: planDate as Any], ofItemAtPath: tree.path(plan))

        let second = try await ScanRun.run(home: tree.home, inventory: store)
        XCTAssertNotEqual(first.snapshotID, second.snapshotID)

        let diff = try await store.diff(from: first.snapshotID, to: second.snapshotID)
        XCTAssertEqual(diff.added.map(\.name), ["new.txt"])
        XCTAssertEqual(diff.addedCount, 1)
        XCTAssertEqual(diff.addedBytes, 50)
        XCTAssertEqual(diff.removed.map(\.name), ["notes.txt"])
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.removedBytes, 1000)
        XCTAssertEqual(diff.changedCount, 2)
        XCTAssertEqual(diff.changedByteDelta, 5000)

        let changes = Dictionary(uniqueKeysWithValues: diff.changed.map { ($0.after.name, $0) })
        let cv = try XCTUnwrap(changes["cv.docx"])
        XCTAssertTrue(cv.kinds.contains(.size))
        XCTAssertEqual(cv.before.logicalSize, 20_000)
        XCTAssertEqual(cv.after.logicalSize, 25_000)
        let materialized = try XCTUnwrap(changes["plan.docx"])
        // setAttributes keeps only microseconds, so the date may differ too; the size does not.
        XCTAssertTrue(materialized.kinds.contains(.placeholder))
        XCTAssertFalse(materialized.kinds.contains(.size))
        XCTAssertTrue(materialized.before.isPlaceholder)
        XCTAssertFalse(materialized.after.isPlaceholder)

        // Reversed, the same changes mirror.
        let back = try await store.diff(from: second.snapshotID, to: first.snapshotID)
        XCTAssertEqual(back.added.map(\.name), ["notes.txt"])
        XCTAssertEqual(back.removed.map(\.name), ["new.txt"])
        XCTAssertEqual(back.changedByteDelta, -5000)

        // A limit caps the lists, never the counts.
        let capped = try await store.diff(from: first.snapshotID, to: second.snapshotID, limit: 0)
        XCTAssertTrue(capped.added.isEmpty && capped.removed.isEmpty && capped.changed.isEmpty)
        XCTAssertEqual(capped.addedCount, 1)
        XCTAssertEqual(capped.changedCount, 2)

        let same = try await store.diff(from: first.snapshotID, to: first.snapshotID)
        XCTAssertEqual(same.addedCount + same.removedCount + same.changedCount, 0)

        let all = try await store.snapshots()
        XCTAssertEqual(all.map(\.id), [first.snapshotID, second.snapshotID])
    }

    func testSearchMatchesAcrossUnicodeNormalizationAndCase() async throws {
        let decomposed = "re\u{301}sume\u{301}.pdf"
        let precomposed = "r\u{E9}sum\u{E9}"
        XCTAssertNotEqual(Array(decomposed.unicodeScalars).count, Array("\(precomposed).pdf".unicodeScalars).count)
        try tree.real(10, "\(FixtureTree.box)/Contracts/\(decomposed)")
        try tree.real(10, "\(FixtureTree.box)/\u{D6}ffentlich/Stra\u{DF}e.txt")
        let run = try await ScanRun.run(home: tree.home)
        let id = run.snapshotID

        for query in [precomposed, "r\u{C9}SUM\u{C9}", "re\u{301}sume\u{301}", "RE\u{301}SUME\u{301}"] {
            let hits = try await run.inventory.search(snapshotID: id, text: query)
            XCTAssertEqual(hits.count, 1, String(reflecting: query))
            // The record keeps the name exactly as the file system has it.
            XCTAssertEqual(hits.first.map { Array($0.name.unicodeScalars) }, Array(decomposed.unicodeScalars))
        }
        let accentless = try await run.inventory.search(snapshotID: id, text: "resume")
        XCTAssertTrue(accentless.isEmpty, "diacritics stay significant")

        let folded = try await run.inventory.search(snapshotID: id, text: "STRASSE")
        XCTAssertEqual(folded.count, 1, "case folding beyond ASCII")
        let folder = try await run.inventory.search(snapshotID: id, text: "\u{F6}ffentlich/", in: .path)
        XCTAssertEqual(folder.count, 1)
    }

    func testInterruptedSnapshotsAreMarkedAndRefusedByTotalsAndDiff() async throws {
        let path = tree.base + "/stale.sqlite"
        let complete: Int64
        let stale: Int64
        do {
            let store = try Inventory(path: path)
            complete = try await ScanRun.run(home: tree.home, inventory: store).snapshotID
            // A scan that never finishes, as if the process were killed.
            stale = try await store.beginSnapshot(homePath: tree.home, placeholderRule: "test")
        }
        let reopened = try Inventory(path: path)
        let snapshot = try await reopened.snapshot(stale)
        XCTAssertEqual(snapshot?.status, .interrupted)
        let kept = try await reopened.snapshot(complete)
        XCTAssertEqual(kept?.status, .complete)

        do {
            _ = try await reopened.diff(from: complete, to: stale)
            XCTFail("diff against an interrupted snapshot must be refused")
        } catch InventoryError.incompleteSnapshot(let id, let status) {
            XCTAssertEqual(id, stale)
            XCTAssertEqual(status, .interrupted)
        }
        do {
            _ = try await reopened.folderTotals(snapshotID: stale)
            XCTFail("expected a refusal")
        } catch InventoryError.incompleteSnapshot {}
        do {
            _ = try await reopened.typeBreakdown(snapshotID: 999)
            XCTFail("expected a refusal")
        } catch InventoryError.noSuchSnapshot(let id) {
            XCTAssertEqual(id, 999)
        }
        let flagged = try await reopened.diff(from: complete, to: stale, allowIncomplete: true)
        XCTAssertEqual(flagged.removedCount, 24, "this is why it is refused by default")
    }

    func testDatabaseOnDiskReopensWithItsData() async throws {
        let path = tree.base + "/inventory.sqlite"
        let id: Int64
        do {
            let store = try Inventory(path: path)
            id = try await ScanRun.run(home: tree.home, inventory: store).snapshotID
        }
        let reopened = try Inventory(path: path)
        let totals = try await reopened.providerTotals(snapshotID: id)
        XCTAssertEqual(totals.reduce(0) { $0 + $1.files }, 24)
        let summaries = try await reopened.rootSummaries(snapshotID: id)
        XCTAssertEqual(summaries.count, 7)
        XCTAssertEqual(summaries.first?.root.id, "icloud-drive/com~apple~CloudDocs")
    }

    func testBatchInsertRollsBackOnFailure() async throws {
        let store = try Inventory(path: ":memory:")
        let id = try await store.beginSnapshot(homePath: "/h", placeholderRule: "test")
        func record(_ path: String) -> FileRecord {
            FileRecord(snapshotID: id, path: path, rootID: "r", provider: "p", relativePath: path,
                       name: path, topLevelFolder: "", facts: FileFacts(logicalSize: 1, allocatedSize: 1),
                       modified: nil, isPackage: false, isPlaceholder: false, contentType: nil,
                       category: .other)
        }
        // The same path twice in one snapshot violates the primary key; nothing is kept.
        do {
            try await store.insert([record("/a"), record("/b"), record("/a")])
            XCTFail("expected a constraint error")
        } catch let error as SQLiteError {
            XCTAssertTrue(error.description.contains("INSERT INTO files"), error.description)
        }
        let totals = try await store.providerTotals(snapshotID: id, allowIncomplete: true)
        XCTAssertTrue(totals.isEmpty)
        try await store.insert([record("/a"), record("/b")])
        let after = try await store.providerTotals(snapshotID: id, allowIncomplete: true)
        XCTAssertEqual(after.first?.files, 2)
        XCTAssertEqual(after.first?.providerName, "p", "falls back to the provider id with no root row")
    }
}
