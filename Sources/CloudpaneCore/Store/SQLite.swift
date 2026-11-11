import Foundation
import SQLite3

/// A SQLite error with the result code, the library's message, and the SQL that caused it.
/// The SQL is included because a bare "near FROM: syntax error" is close to undiagnosable.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        var text = "SQLite error \(code): \(message)"
        if let sql { text += "\n  in: \(sql)" }
        return text
    }
}

/// SQLITE_TRANSIENT tells SQLite to copy bound bytes. The SDK does not expose it to Swift
/// because it is a macro casting -1 to a function pointer. With SQLITE_STATIC, SQLite would
/// keep a pointer into a Swift string buffer that is freed as soon as the bind returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin wrapper over one sqlite3 connection. Not Sendable and not synchronized; Inventory,
/// an actor, owns it and serializes access.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    /// Opens or creates the database. Deliberately without SQLITE_OPEN_NOFOLLOW: SQLite
    /// applies it to every path component, and /var on macOS is a symbolic link, so any path
    /// under the temporary directory would fail to open.
    init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: result, message: message, sql: nil)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "connection closed", sql: sql) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw SQLiteError(code: result, message: message, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "connection closed", sql: sql) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return SQLiteStatement(statement: statement, connection: handle, sql: sql)
    }

    /// Runs body in a transaction and rolls back on any thrown error. IMMEDIATE takes the
    /// write lock at BEGIN, where the busy timeout can handle contention, rather than midway
    /// through a batch.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Makes the statement running on this connection stop with SQLITE_INTERRUPT. Safe to
    /// call from another thread, which is how a canceled grade stops mid-query.
    func interrupt() {
        if let handle { sqlite3_interrupt(handle) }
    }

    var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    /// Reads a PRAGMA that returns a single integer.
    func integerPragma(_ pragma: String) throws -> Int64 {
        let statement = try prepare("PRAGMA \(pragma)")
        return try statement.step() ? statement.int64(0) : 0
    }
}

/// One prepared statement, reset and reused across a batch rather than prepared per row.
final class SQLiteStatement {
    private var statement: OpaquePointer?
    private let connection: OpaquePointer
    private let sql: String

    init(statement: OpaquePointer, connection: OpaquePointer, sql: String) {
        self.statement = statement
        self.connection = connection
        self.sql = sql
    }

    deinit { finalize() }

    func finalize() {
        if let statement { sqlite3_finalize(statement) }
        statement = nil
    }

    /// Advances the statement. Returns true when a row is available.
    @discardableResult
    func step() throws -> Bool {
        guard let statement else { throw SQLiteError(code: SQLITE_MISUSE, message: "statement finalized", sql: sql) }
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(connection)), sql: sql)
        }
    }

    func reset() {
        guard let statement else { return }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // MARK: Binding (1-based, as SQLite counts)

    func bind(_ index: Int32, _ value: Int64?) {
        guard let statement else { return }
        if let value { sqlite3_bind_int64(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    func bind(_ index: Int32, _ value: Int?) {
        bind(index, value.map(Int64.init))
    }

    func bind(_ index: Int32, _ value: Bool) {
        bind(index, Int64(value ? 1 : 0))
    }

    func bind(_ index: Int32, _ value: Double?) {
        guard let statement else { return }
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    func bind(_ index: Int32, _ value: Date?) {
        bind(index, value.map(\.timeIntervalSince1970))
    }

    func bind(_ index: Int32, _ value: String?) {
        guard let statement else { return }
        if let value { sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(statement, index) }
    }

    func bind(_ index: Int32, _ value: Data?) {
        guard let statement else { return }
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        if value.isEmpty {
            // A zero-length blob with a nil pointer is undefined behavior in the C API.
            sqlite3_bind_zeroblob(statement, index, 0)
            return
        }
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
    }

    // MARK: Reading (0-based, as SQLite counts)

    func int64(_ index: Int32) -> Int64 {
        guard let statement else { return 0 }
        return sqlite3_column_int64(statement, index)
    }

    func int64OrNil(_ index: Int32) -> Int64? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    func int(_ index: Int32) -> Int { Int(int64(index)) }

    func bool(_ index: Int32) -> Bool { int64(index) != 0 }

    func double(_ index: Int32) -> Double {
        guard let statement else { return 0 }
        return sqlite3_column_double(statement, index)
    }

    func dateOrNil(_ index: Int32) -> Date? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    func data(_ index: Int32) -> Data? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func string(_ index: Int32) -> String? {
        guard let statement, let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}
