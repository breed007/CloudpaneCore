import XCTest
@testable import CloudpaneCore

final class ExportTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUpWithError() throws {
        tree = try FixtureTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    func testFieldEscaping() {
        XCTAssertEqual(CSV.field("plain.txt"), "plain.txt")
        XCTAssertEqual(CSV.field(""), "")
        XCTAssertEqual(CSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.field("line\nbreak"), "\"line\nbreak\"")
        XCTAssertEqual(CSV.field("cr\rhere"), "\"cr\rhere\"")
        XCTAssertEqual(CSV.field("crlf\r\nhere"), "\"crlf\r\nhere\"")
        XCTAssertEqual(CSV.field(" padded "), "\" padded \"")
        XCTAssertEqual(CSV.field("a|b;c'd"), "a|b;c'd")
        XCTAssertEqual(CSV.row(["a", "b"]), "a,b\r\n")
    }

    func testFormulaNeutralization() {
        let on = CSVOptions()
        XCTAssertEqual(CSV.textField("=cmd.png", options: on), "'=cmd.png")
        XCTAssertEqual(CSV.textField("+1", options: on), "'+1")
        XCTAssertEqual(CSV.textField("-x", options: on), "'-x")
        XCTAssertEqual(CSV.textField("@home", options: on), "'@home")
        XCTAssertEqual(CSV.textField("\tx", options: on), "'\tx")
        XCTAssertEqual(CSV.textField("=a,b", options: on), "\"'=a,b\"")
        XCTAssertEqual(CSV.textField("a=b", options: on), "a=b")
        XCTAssertEqual(CSV.textField("=cmd.png", options: CSVOptions(neutralizeFormulas: false)), "=cmd.png")
    }

    func testCSVExportRoundTrips() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let url = URL(fileURLWithPath: tree.base + "/export.csv")
        try await run.inventory.exportCSV(snapshotID: run.snapshotID, to: url)

        let data = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\r\n"))
        let rows = try parseCSV(text)
        XCTAssertEqual(rows.first, Inventory.csvHeader)
        XCTAssertEqual(rows.count, 1 + 24)
        XCTAssertTrue(rows.allSatisfy { $0.count == Inventory.csvHeader.count }, "every row has every column")

        let column = Dictionary(uniqueKeysWithValues: Inventory.csvHeader.enumerated().map { ($1, $0) })
        let names = Set(rows.dropFirst().map { $0[column["name"]!] })
        XCTAssertTrue(names.contains("a,b \"quoted\".txt"))
        XCTAssertTrue(names.contains("line\nbreak.txt"))
        XCTAssertTrue(names.contains("a|b.png"))
        XCTAssertTrue(names.contains("'=cmd.png"), "formula neutralized")

        let logical = rows.dropFirst().compactMap { Int64($0[column["logical_size"]!]) }.reduce(0, +)
        let totals = try await run.inventory.providerTotals(snapshotID: run.snapshotID)
        XCTAssertEqual(logical, totals.reduce(0) { $0 + $1.logicalBytes })

        let report = try XCTUnwrap(rows.first { $0[column["name"]!] == "report.pdf" })
        XCTAssertEqual(report[column["is_placeholder"]!], "true")
        XCTAssertEqual(report[column["allocated_size"]!], "0")
        XCTAssertEqual(report[column["download_status"]!], "none")
        XCTAssertEqual(report[column["sha256"]!], "")
        XCTAssertNotNil(parseTimestamp(report[column["modified"]!]))

        // Exporting to a name that exists fails and leaves the existing file alone.
        do {
            try await run.inventory.exportCSV(snapshotID: run.snapshotID, to: url,
                                              options: CSVOptions(neutralizeFormulas: false))
            XCTFail("an export must never replace a file")
        } catch let error as ExportError {
            XCTAssertEqual(error, .destinationExists(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), data)

        let raw = URL(fileURLWithPath: tree.base + "/raw.csv")
        try await run.inventory.exportCSV(snapshotID: run.snapshotID, to: raw,
                                          options: CSVOptions(neutralizeFormulas: false))
        let again = try parseCSV(String(contentsOf: raw, encoding: .utf8))
        XCTAssertTrue(again.contains { $0[column["name"]!] == "=cmd.png" })
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tree.base)
        XCTAssertEqual(Set(leftovers), ["home", "backup", "outside", "export.csv", "raw.csv"])
    }

    /// A file that takes the name while the export is being written is not replaced either.
    func testNameTakenDuringExportIsNotReplaced() throws {
        let url = URL(fileURLWithPath: tree.base + "/race.json")
        let writer = try ExportWriter(url: url)
        defer { writer.close() }
        try writer.write("{\"from\":\"export\"}")
        try Data("theirs".utf8).write(to: url)
        XCTAssertThrowsError(try writer.finish()) { error in
            XCTAssertEqual(error as? ExportError, .destinationExists(url.path))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs")
        writer.close()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tree.base)
        XCTAssertEqual(Set(leftovers), ["home", "backup", "outside", "race.json"])
    }

    func testJSONExportIsVerbatim() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let url = URL(fileURLWithPath: tree.base + "/export.json")
        try await run.inventory.exportJSON(snapshotID: run.snapshotID, to: url)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let snapshot = try XCTUnwrap(object?["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["id"] as? Int, Int(run.snapshotID))
        XCTAssertEqual(snapshot["status"] as? String, "complete")
        XCTAssertEqual((object?["roots"] as? [Any])?.count, 7)
        let files = try XCTUnwrap(object?["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 24)

        let names = Set(files.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("=cmd.png"), "JSON is never neutralized")
        XCTAssertTrue(names.contains("line\nbreak.txt"))
        XCTAssertTrue(names.contains("a,b \"quoted\".txt"))

        let budget = try XCTUnwrap(files.first { $0["name"] as? String == "Budget.xlsx" })
        XCTAssertEqual(budget["logicalSize"] as? Int, 12_288)
        XCTAssertEqual(budget["topLevelFolder"] as? String, "My Drive")
        XCTAssertEqual(budget["isPlaceholder"] as? Bool, false)
        let modified = try XCTUnwrap(budget["modified"] as? String)
        let parsed = try XCTUnwrap(parseTimestamp(modified))
        let original = try await run.inventory.search(snapshotID: run.snapshotID, text: "Budget").first?.modified
        XCTAssertEqual(parsed, original?.timeIntervalSince1970 ?? 0, accuracy: 0.000_001)
    }

    func testTimestampsKeepMicroseconds() {
        XCTAssertEqual(exportTimestamp(Date(timeIntervalSince1970: 1_700_000_000.123456)),
                       "2023-11-14T22:13:20.123456Z")
        XCTAssertEqual(exportTimestamp(Date(timeIntervalSince1970: 1_700_000_000)),
                       "2023-11-14T22:13:20.000000Z")
        XCTAssertEqual(exportTimestamp(Date(timeIntervalSince1970: 1_700_000_000.9999996)),
                       "2023-11-14T22:13:21.000000Z", "rounding carries into the seconds")
        XCTAssertEqual(exportTimestamp(Date(timeIntervalSince1970: -0.25)),
                       "1969-12-31T23:59:59.750000Z")
    }

    /// Seconds since 1970 from an exported timestamp, keeping all six fractional digits.
    private func parseTimestamp(_ text: String) -> Double? {
        let parts = text.dropLast().split(separator: ".")
        guard text.hasSuffix("Z"), parts.count == 2, parts[1].count == 6, let micros = Double(parts[1]),
              let whole = try? Date(String(parts[0]) + "Z", strategy: Date.ISO8601FormatStyle(timeZone: .gmt))
        else { return nil }
        return whole.timeIntervalSince1970 + micros / 1_000_000
    }

    func testFailedExportLeavesNoFile() async throws {
        let run = try await ScanRun.run(home: tree.home)
        let url = URL(fileURLWithPath: tree.base + "/missing-folder/export.csv")
        do {
            try await run.inventory.exportCSV(snapshotID: run.snapshotID, to: url)
            XCTFail("expected an error")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A strict RFC 4180 reader: fails on a stray quote instead of guessing.
    private func parseCSV(_ text: String) throws -> [[String]] {
        struct Malformed: Error {}
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { chars.removeFirst(); field.unicodeScalars.append("\"") }
                    else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"":
                guard field.isEmpty else { throw Malformed() }
                quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                guard chars.popFirst() == "\n" else { throw Malformed() }
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            case "\n":
                throw Malformed()
            default:
                field.unicodeScalars.append(c)
            }
        }
        guard !quoted, field.isEmpty, row.isEmpty else { throw Malformed() }
        return rows
    }
}
