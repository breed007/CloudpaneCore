import Darwin
import Foundation

public enum ExportError: Error, CustomStringConvertible, Sendable, Equatable {
    /// Something already has the export's name. Export never replaces a file; pick
    /// another name and export again.
    case destinationExists(String)

    public var description: String {
        switch self {
        case .destinationExists(let path): return "A file named \((path as NSString).lastPathComponent) already exists"
        }
    }
}

public struct CSVOptions: Sendable {
    /// Prefixes a text field that starts with =, +, -, @, tab or carriage return with a
    /// single quote, so a spreadsheet does not run a file name as a formula. Changes how such
    /// names appear in the CSV; JSON export is always verbatim.
    public var neutralizeFormulas: Bool

    public init(neutralizeFormulas: Bool = true) {
        self.neutralizeFormulas = neutralizeFormulas
    }
}

/// RFC 4180 field and row encoding.
public enum CSV {
    /// Quotes a field when it contains a comma, a double quote, CR or LF, or starts or ends
    /// with a space, and doubles any double quotes inside it.
    public static func field(_ value: String) -> String {
        let needsQuotes = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A text field from user data, with formula neutralization applied when asked.
    public static func textField(_ value: String, options: CSVOptions) -> String {
        guard options.neutralizeFormulas, let first = value.unicodeScalars.first,
              "=+-@\t\r".unicodeScalars.contains(first) else { return field(value) }
        return field("'" + value)
    }

    /// Fields joined with commas and terminated with CRLF, as RFC 4180 specifies.
    public static func row(_ fields: [String]) -> String {
        fields.joined(separator: ",") + "\r\n"
    }
}

/// ISO 8601 in UTC with six fractional digits, as in "2023-11-14T22:13:20.123456Z".
/// Rounded to the microsecond; the system's date format styles stop at milliseconds, which
/// would lose most of what the inventory stores. File-system timestamps can carry
/// nanoseconds, so digits below the microsecond are not exported.
public func exportTimestamp(_ date: Date) -> String {
    let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    var seconds = micros / 1_000_000
    var fraction = micros % 1_000_000
    if fraction < 0 {
        fraction += 1_000_000
        seconds -= 1
    }
    let whole = Date(timeIntervalSince1970: TimeInterval(seconds))
        .formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
    return String(whole.dropLast()) + String(format: ".%06lldZ", fraction)
}

extension Inventory {
    public static let csvHeader = [
        "snapshot_id", "provider", "root_id", "top_level_folder", "relative_path", "name", "path",
        "logical_size", "allocated_size", "modified", "is_placeholder", "is_dataless",
        "is_compressed", "is_package", "is_ubiquitous", "download_status", "content_type",
        "category", "sha256",
    ]

    /// Writes every file in a snapshot as CSV, one row per record, streamed to disk.
    public func exportCSV(snapshotID: Int64, to url: URL, options: CSVOptions = CSVOptions()) throws {
        let writer = try ExportWriter(url: url)
        defer { writer.close() }
        try writer.write(CSV.row(Inventory.csvHeader))
        try forEachFile(snapshotID: snapshotID) { record in
            let text = { (value: String) in CSV.textField(value, options: options) }
            let fields: [String] = [
                String(record.snapshotID), CSV.field(record.provider), text(record.rootID),
                text(record.topLevelFolder), text(record.relativePath), text(record.name),
                text(record.path), record.logicalSize.map(String.init) ?? "",
                record.allocatedSize.map(String.init) ?? "",
                record.modified.map(exportTimestamp) ?? "",
                String(record.isPlaceholder), String(record.isDataless), String(record.isCompressed),
                String(record.isPackage), String(record.isUbiquitous), record.downloadStatus.rawValue,
                CSV.field(record.contentType ?? ""), record.category.rawValue, record.sha256 ?? "",
            ]
            try writer.write(CSV.row(fields))
        }
        try writer.finish()
    }

    /// Writes a snapshot as one JSON object: the snapshot, its per-root totals, and every
    /// file. Files are encoded one at a time and streamed, so memory stays flat.
    public func exportJSON(snapshotID: Int64, to url: URL) throws {
        guard let snapshot = try snapshot(snapshotID) else {
            throw SQLiteError(code: 0, message: "no snapshot \(snapshotID)", sql: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(exportTimestamp(date))
        }
        let writer = try ExportWriter(url: url)
        defer { writer.close() }
        try writer.write("{\"snapshot\":")
        try writer.write(encoder.encode(snapshot))
        try writer.write(",\"roots\":")
        try writer.write(encoder.encode(rootSummaries(snapshotID: snapshotID)))
        try writer.write(",\"files\":[")
        var first = true
        try forEachFile(snapshotID: snapshotID) { record in
            try writer.write(first ? "\n" : ",\n")
            first = false
            try writer.write(encoder.encode(record))
        }
        try writer.write("\n]}\n")
        try writer.finish()
    }
}

/// Writes finished bytes, such as a rendered report, to a new file at url. Like the
/// exports it never replaces anything: it fails with ExportError.destinationExists when the
/// name is taken, even by a file that appeared while it ran.
public func writeNewFile(_ data: Data, to url: URL) throws {
    let writer = try ExportWriter(url: url)
    defer { writer.close() }
    try writer.write(data)
    try writer.finish()
}

/// Buffered writes to a new file. The export is written in the system's item-replacement
/// directory for the target's volume (the location safe-save uses, which the App Sandbox
/// allows) and moved into place at the end, so a failed export never leaves a truncated file
/// under the real name.
final class ExportWriter {
    private let target: URL
    private let directory: URL
    private let temporary: URL
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false

    init(url: URL) throws {
        target = url
        directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: url, create: true)
        temporary = directory.appendingPathComponent(url.lastPathComponent)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        handle = try FileHandle(forWritingTo: temporary)
    }

    func write(_ text: String) throws { try write(Data(text.utf8)) }

    func write(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= 1 << 16 { try flush() }
    }

    private func flush() throws {
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Moves the finished file into place with renamex_np(2) and RENAME_EXCL: one atomic
    /// step that fails with EEXIST if anything already has the name, so an existing file is
    /// never replaced, even one that appeared while the export ran.
    func finish() throws {
        try flush()
        try handle.close()
        guard renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw ExportError.destinationExists(target.path) }
            throw POSIXError(POSIXError.Code(rawValue: code) ?? .EIO)
        }
        finished = true
        try? FileManager.default.removeItem(at: directory)
    }

    /// Closes and removes the temporary file if finish was never reached.
    func close() {
        guard !finished else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
