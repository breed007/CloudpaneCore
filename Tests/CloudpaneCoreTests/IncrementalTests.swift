import XCTest
@testable import CloudpaneCore

final class IncrementalTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws { tree = try FixtureTree() }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private func roots() -> [ScanRoot] {
        ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
    }

    private func versions(_ store: Inventory) async throws -> Int {
        try await store.versionCount()
    }

    /// Edits of every kind, recorded incrementally, give the same results as a full rescan.
    func testIncrementalSnapshotMatchesAFullRescan() async throws {
        let store = try Inventory(path: tree.base + "/inc.sqlite")
        let first = try await ScanRun.run(home: tree.home, inventory: store).snapshotID

        let db = tree.path(FixtureTree.dropbox)
        let icloud = tree.path(FixtureTree.iCloud)
        try tree.real(7000, "\(FixtureTree.dropbox)/Photos/new.jpg")
        try FileManager.default.removeItem(atPath: icloud + "/Documents/notes.txt")
        try tree.real(25_000, "\(FixtureTree.oneDrivePersonal)/Documents/cv.docx")
        try tree.real(500, "\(FixtureTree.googleDrive)/My Drive/NewDir/inner/a.txt")
        try FileManager.default.removeItem(atPath: tree.path(FixtureTree.box + "/Contracts"))
        try tree.real(300, "\(FixtureTree.dropbox)/Tool.app/Contents/Resources/extra.dat")
        try FileManager.default.createDirectory(atPath: db + "/Moved", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: db + "/Photos/trip/day1.jpg", toPath: db + "/Moved/day1.jpg")

        // File-level paths, as FSEvents reports them.
        let changed: Set<String> = [
            db + "/Photos/new.jpg", icloud + "/Documents/notes.txt",
            tree.path(FixtureTree.oneDrivePersonal + "/Documents/cv.docx"),
            tree.path(FixtureTree.googleDrive + "/My Drive/NewDir"),
            tree.path(FixtureTree.googleDrive + "/My Drive/NewDir/inner/a.txt"),
            tree.path(FixtureTree.box + "/Contracts/nda.pdf"), tree.path(FixtureTree.box + "/Contracts"),
            db + "/Tool.app/Contents/Resources/extra.dat", db + "/Photos/trip/day1.jpg", db + "/Moved/day1.jpg",
        ]
        let before = try await versions(store)
        let outcome = try await store.recordIncremental(IncrementalScanner(roots: roots(), changedPaths: changed),
                                                        homePath: tree.home)
        guard case .recorded(let incremental) = outcome else { return XCTFail("\(outcome)") }
        let written = try await versions(store) - before
        XCTAssertLessThanOrEqual(written, 8, "only changed files are written, not the whole tree")

        let full = try await ScanRun.run(home: tree.home, inventory: store).snapshotID
        let afterFull = try await versions(store)
        XCTAssertEqual(afterFull, before + written, "a full rescan of an unchanged tree writes nothing")

        let a = try await store.providerTotals(snapshotID: incremental, allowIncomplete: true)
        let b = try await store.providerTotals(snapshotID: full)
        XCTAssertEqual(a, b)
        let folders = try await store.folderTotals(snapshotID: full)
        // The incremental snapshot is no longer the latest; reading it uses the version range.
        let incrementalFolders = try await store.folderTotals(snapshotID: incremental)
        XCTAssertEqual(incrementalFolders, folders)
        let typesA = try await store.typeBreakdown(snapshotID: incremental)
        let typesB = try await store.typeBreakdown(snapshotID: full)
        XCTAssertEqual(typesA, typesB)

        let rootsA = try await store.rootSummaries(snapshotID: incremental)
        let rootsB = try await store.rootSummaries(snapshotID: full)
        XCTAssertEqual(rootsA.map(\.root.id), rootsB.map(\.root.id))
        for (x, y) in zip(rootsA, rootsB) {
            XCTAssertEqual([x.files, x.packages, x.placeholders, x.zeroByte, x.dataless],
                           [y.files, y.packages, y.placeholders, y.zeroByte, y.dataless], x.root.id)
            XCTAssertEqual([x.logicalBytes, x.allocatedBytes, x.placeholderBytes, x.packageLogicalBytes],
                           [y.logicalBytes, y.allocatedBytes, y.placeholderBytes, y.packageLogicalBytes], x.root.id)
        }

        let facts = try ProviderFacts.bundled()
        let gradeA = try await store.grade(snapshotID: incremental, facts: facts)
        let gradeB = try await store.grade(snapshotID: full, facts: facts)
        XCTAssertEqual(gradeA.folders.map(\.id), gradeB.folders.map(\.id))
        XCTAssertEqual(gradeA.folders.map(\.letter), gradeB.folders.map(\.letter))
        XCTAssertEqual(gradeA.singlePoint.totalBytes, gradeB.singlePoint.totalBytes)

        // What changed, including the move.
        let diff = try await store.diff(from: first, to: incremental)
        XCTAssertEqual(diff.moved.map(\.after.name), ["day1.jpg"])
        XCTAssertEqual(diff.moved.first?.before.relativePath, "Photos/trip/day1.jpg")
        XCTAssertEqual(diff.moved.first?.after.relativePath, "Moved/day1.jpg")
        XCTAssertEqual(Set(diff.added.map(\.name)), ["new.jpg", "a.txt"])
        XCTAssertEqual(Set(diff.removed.map(\.name)), ["notes.txt", "nda.pdf", "msa.pdf"])
        XCTAssertEqual(Set(diff.changed.map(\.after.name)), ["cv.docx", "Tool.app"])
        let nothing = try await store.diff(from: incremental, to: full)
        XCTAssertEqual(nothing.addedCount + nothing.removedCount + nothing.changedCount + nothing.movedCount, 0)
    }

    func testChangesInsideHiddenFoldersAreIgnoredAndRootChangesNeedAFullScan() async throws {
        let store = try Inventory(path: ":memory:")
        _ = try await ScanRun.run(home: tree.home, inventory: store)
        let db = tree.path(FixtureTree.dropbox)
        try tree.real(10, "\(FixtureTree.dropbox)/.dropbox.cache/new.bin")
        let hidden = try await store.recordIncremental(
            IncrementalScanner(roots: roots(), changedPaths: [db + "/.dropbox.cache/new.bin"]), homePath: tree.home)
        guard case .recorded(let id) = hidden else { return XCTFail("\(hidden)") }
        let found = try await store.search(snapshotID: id, text: "new.bin")
        XCTAssertTrue(found.isEmpty)

        // The roots as the watcher knew them before the new provider folder appeared.
        let known = roots()
        let cloudStorage = tree.path(FixtureTree.cloudStorage)
        try tree.folder(FixtureTree.cloudStorage + "/NewProvider-x")
        let added = try await store.recordIncremental(
            IncrementalScanner(roots: known, changedPaths: [cloudStorage + "/NewProvider-x"], rootParents: [cloudStorage]),
            homePath: tree.home)
        XCTAssertEqual(added, .needsFullRescan("A cloud storage folder was added or removed."))
        let snapshots = try await store.snapshots()
        XCTAssertFalse(snapshots.contains { $0.status != .complete }, "the abandoned attempt leaves no snapshot")
    }

    func testIncrementalNeedsABase() async throws {
        let store = try Inventory(path: ":memory:")
        let outcome = try await store.recordIncremental(IncrementalScanner(roots: roots(), changedPaths: []),
                                                        homePath: tree.home)
        XCTAssertEqual(outcome, .needsFullRescan("There is no complete scan to build on yet."))
    }
}

extension Inventory {
    func versionCount() throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM files")
        _ = try statement.step()
        return statement.int(0)
    }
}
