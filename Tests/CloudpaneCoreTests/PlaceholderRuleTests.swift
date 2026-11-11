import UniformTypeIdentifiers
import XCTest
@testable import CloudpaneCore

final class PlaceholderRuleTests: XCTestCase {
    private let rule = PlaceholderRule.default

    private func check(_ facts: FileFacts, _ expected: Bool, _ why: String,
                       line: UInt = #line) {
        XCTAssertEqual(rule.isPlaceholder(facts), expected, why, line: line)
    }

    func testDefaultRule() {
        check(FileFacts(logicalSize: 0, allocatedSize: 4096, isDataless: true), true,
              "the dataless flag wins over every other fact")
        check(FileFacts(logicalSize: 100, allocatedSize: 0), true, "sparse, not ubiquitous")
        check(FileFacts(logicalSize: 100, allocatedSize: nil), true, "no allocated size reported counts as 0")
        check(FileFacts(logicalSize: 0, allocatedSize: 0), false, "an empty file is not a placeholder")
        check(FileFacts(logicalSize: nil, allocatedSize: 0), false, "no logical size, nothing to fetch")
        check(FileFacts(logicalSize: 100, allocatedSize: 4096), false, "allocated means local")
        check(FileFacts(logicalSize: 100, allocatedSize: 4096, isUbiquitous: true,
                        downloadStatus: .notDownloaded), false,
              "strict: allocated blocks outweigh a notDownloaded status")
        check(FileFacts(logicalSize: 100, allocatedSize: 0, isUbiquitous: true,
                        downloadStatus: .current), false, "a current download is local")
        check(FileFacts(logicalSize: 100, allocatedSize: 0, isUbiquitous: true,
                        downloadStatus: .downloaded), true, "downloaded is not current")
        check(FileFacts(logicalSize: 100, allocatedSize: 0, isCompressed: true), false,
              "a compressed file keeps its data in an attribute")
        XCTAssertEqual(rule.id, "dataless-or-strict-v1")
    }

    func testRuleIsSwappableAndRecordedWithTheSnapshot() async throws {
        let tree = try FixtureTree()
        defer { tree.remove() }
        let everything = PlaceholderRule(id: "test-everything", summary: "all") { _ in true }
        let roots = ProviderCatalog(home: URL(fileURLWithPath: tree.home)).detect().scanRoots()
        let store = try Inventory(path: ":memory:")
        let id = try await store.recordScan(Scanner(roots: roots, placeholderRule: everything),
                                            homePath: tree.home)
        let snapshot = try await store.snapshot(id)
        XCTAssertEqual(snapshot?.placeholderRule, "test-everything")
        let totals = try await store.providerTotals(snapshotID: id)
        XCTAssertEqual(totals.reduce(0) { $0 + $1.placeholders }, 24)
    }

    func testCategories() {
        let cases: [(String, FileCategory)] = [
            ("pdf", .document), ("docx", .document), ("xlsx", .document), ("txt", .document),
            ("swift", .code), ("zip", .archive), ("png", .image), ("heic", .image),
            ("mov", .video), ("mp3", .audio), ("app", .application),
        ]
        for (ext, category) in cases {
            XCTAssertEqual(FileCategory(contentType: UTType(filenameExtension: ext)), category, ext)
        }
        XCTAssertEqual(FileCategory(contentType: nil), .other)
        let bin = FileCategory.effectiveType(UTType(filenameExtension: "bin"))
        XCTAssertEqual(bin, .data)
        XCTAssertEqual(FileCategory(contentType: bin), .other)
        XCTAssertEqual(FileCategory.effectiveType(.pdf), .pdf)
        XCTAssertEqual(FileCategory(contentType: UTType(filenameExtension: "Hale-Family")), .other)
    }

    func testTopLevelFolder() {
        XCTAssertEqual(FileRecord.topLevelFolder(relativePath: "a.txt", depth: 1), "")
        XCTAssertEqual(FileRecord.topLevelFolder(relativePath: "Docs/a.txt", depth: 1), "Docs")
        XCTAssertEqual(FileRecord.topLevelFolder(relativePath: "Docs/x/y/a.txt", depth: 1), "Docs")
        XCTAssertEqual(FileRecord.topLevelFolder(relativePath: "My Drive/a.txt", depth: 2), "My Drive")
        XCTAssertEqual(FileRecord.topLevelFolder(relativePath: "My Drive/P/x/a.txt", depth: 2), "My Drive/P")
    }
}
