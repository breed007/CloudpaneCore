import Foundation
import SQLite3

/// SQLITE_INTERRUPT as a plain constant for pattern matching.
let SQLITE_INTERRUPT_CODE = SQLITE_INTERRUPT

/// Carries the grading connection into the detached task and lets the cancel handler
/// interrupt it from another thread. sqlite3_interrupt is documented as thread-safe; the
/// connection is otherwise used only by the grading task.
final class ReaderHandle: @unchecked Sendable {
    let connection: SQLiteConnection
    init(_ connection: SQLiteConnection) { self.connection = connection }
}

extension Inventory {
    /// Seconds two modification dates may differ and still be the same file: the strong
    /// duplicate tier (same name, same size, modification date within 2 seconds).
    static let matchWindow: Double = 2

    /// Grades every top-level folder of every provider root in a complete snapshot.
    ///
    /// Content matching (see DECISIONS.md): a file is present in another location when that
    /// location has a downloaded file with the same name (SearchKey form), the same logical
    /// size, and a modification date within 2 seconds. Only downloaded files hold content,
    /// so a placeholder never counts as a copy anywhere. Empty files hold nothing to lose
    /// and are left out, and a folder of only empty files is not graded.
    ///
    /// Speed: one pass over the graded files, whatever the number of backups. Every
    /// location gets a bit (this Mac is bit 0, backups 1 to 62); downloaded files go into a
    /// temporary table with their location's bit, under a covering index on (name, size,
    /// date, bit, hash). For each graded file a single range seek collects the bits of every
    /// location holding a match as SUM(DISTINCT bit), and a second lookup the bits of every
    /// backup with the same name and size at any date. Rows are grouped by folder and masks,
    /// and the masks are unpacked per location in Swift. More than 62 backups would not fit
    /// the mask; the rest use one pass each. gradeQueryPlans() lets a test check that no step
    /// scans the key tables.
    ///
    /// For a database on disk, grading runs on its own read-only connection off the actor,
    /// so search, totals and plans are not held up while it works; WAL lets the two
    /// connections read at once. An in-memory database cannot be opened twice, so it is
    /// graded on the actor's connection.
    public nonisolated func grade(snapshotID: Int64, facts: ProviderFacts, subscriptions: [Subscription] = [],
                                  singlePointLimit: Int = 500) async throws -> GradeReport {
        try await grade(snapshotID: snapshotID, facts: facts, subscriptions: subscriptions,
                        singlePointLimit: singlePointLimit, afterTables: nil)
    }

    /// afterTables is a test seam: called on the grading thread once the grade tables are
    /// built, before the work checks for cancellation and runs its passes.
    nonisolated func grade(snapshotID: Int64, facts: ProviderFacts, subscriptions: [Subscription],
                           singlePointLimit: Int, afterTables: (@Sendable () -> Void)?) async throws -> GradeReport {
        if path == ":memory:" {
            return try await gradeOnActor(snapshotID: snapshotID, facts: facts, subscriptions: subscriptions,
                                          singlePointLimit: singlePointLimit)
        }
        // Canceling the caller cancels the work and interrupts the query in flight.
        let reader = ReaderHandle(try SQLiteConnection(path: path, readOnly: true))
        _ = try? reader.connection.execute("PRAGMA mmap_size = 268435456; PRAGMA cache_size = -65536")
        let work = Task.detached(priority: .utility) {
            try Inventory.grade(snapshotID: snapshotID, facts: facts, subscriptions: subscriptions,
                                singlePointLimit: singlePointLimit, in: reader.connection, afterTables: afterTables)
        }
        return try await withTaskCancellationHandler {
            do {
                return try await work.value
            } catch let error as SQLiteError where error.code == SQLITE_INTERRUPT_CODE {
                throw CancellationError()
            }
        } onCancel: {
            work.cancel()
            reader.connection.interrupt()
        }
    }

    private func gradeOnActor(snapshotID: Int64, facts: ProviderFacts, subscriptions: [Subscription],
                              singlePointLimit: Int) throws -> GradeReport {
        try Inventory.grade(snapshotID: snapshotID, facts: facts, subscriptions: subscriptions,
                            singlePointLimit: singlePointLimit, in: db)
    }

    /// Locations a mask can carry: bit 0 for this Mac, 1 to 62 for backups.
    static let maskedBackupLimit = 62

    static func grade(snapshotID: Int64, facts: ProviderFacts, subscriptions: [Subscription],
                      singlePointLimit: Int, in db: SQLiteConnection,
                      afterTables: (@Sendable () -> Void)? = nil) throws -> GradeReport {
        try Task.checkCancellation()
        try requireComplete(snapshotID, allowIncomplete: false, in: db)
        let scope = try rows(of: snapshotID, in: db)
        let roots = try rootSummaries(snapshotID: snapshotID, in: db).map(\.root)
        let byID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let backups = roots.filter { $0.kind == .backup }.map(\.id).sorted()
        let masked = Array(backups.prefix(maskedBackupLimit))
        try buildGradeTables(scope: scope, masked: masked, in: db)
        defer { try? db.execute(dropGradeTables) }
        afterTables?()
        try Task.checkCancellation()

        struct Totals {
            var provider = ""
            var files = 0, localFiles = 0
            var bytes: Int64 = 0, localBytes: Int64 = 0
            var held: [String: (files: Int, bytes: Int64)] = [:]
            var nearly: [String: (files: Int, bytes: Int64)] = [:]
        }
        var totals: [String: [String: Totals]] = [:]
        func add(_ table: inout [String: (files: Int, bytes: Int64)], _ key: String, _ files: Int, _ bytes: Int64) {
            let current = table[key] ?? (0, 0)
            table[key] = (current.files + files, current.bytes + bytes)
        }

        let pass = try db.prepare(passSQL)
        while try pass.step() {
            let s = pass
            let (root, folder) = (s.string(0) ?? "", s.string(2) ?? "")
            let local = s.bool(3)
            let strong = s.int64(4), near = s.int64(5)
            let files = s.int(6), bytes = s.int64(7)
            var t = totals[root]?[folder] ?? Totals()
            t.provider = s.string(1) ?? ""
            t.files += files
            t.bytes += bytes
            if local {
                t.localFiles += files
                t.localBytes += bytes
            }
            for (index, backup) in masked.enumerated() {
                let bit = Int64(1) << Int64(index + 1)
                if strong & bit != 0 {
                    add(&t.held, backup, files, bytes)
                } else if near & bit != 0 {
                    add(&t.nearly, backup, files, bytes)
                }
            }
            totals[root, default: [:]][folder] = t
        }

        // Backups past the mask's capacity: one pass each.
        for backup in backups.dropFirst(maskedBackupLimit) {
            try Task.checkCancellation()
            let statement = try db.prepare(overflowSQL)
            statement.bind(1, backup)
            while try statement.step() {
                let s = statement
                let (root, folder) = (s.string(0) ?? "", s.string(1) ?? "")
                guard var t = totals[root]?[folder] else { continue }
                if s.int(2) > 0 { add(&t.held, backup, s.int(2), s.int64(3)) }
                if s.int(4) > 0 { add(&t.nearly, backup, s.int(4), s.int64(5)) }
                totals[root]?[folder] = t
            }
        }
        try Task.checkCancellation()

        var evidence: [FolderEvidence] = []
        for (rootID, byFolder) in totals {
            let root = byID[rootID]
            for (folder, t) in byFolder {
                evidence.append(FolderEvidence(
                    rootID: rootID, provider: t.provider, providerName: root?.providerName ?? t.provider,
                    account: root?.name ?? rootID, folder: folder, files: t.files, bytes: t.bytes,
                    localFiles: t.localFiles, localBytes: t.localBytes, backups: t.held, dateMismatches: t.nearly))
            }
        }
        let paid = Set(subscriptions.filter { !$0.inactive && ($0.price > 0 || $0.bundle == .employerPaid) }
            .map(\.provider))
        return Grader.report(snapshotID: snapshotID, evidence: evidence, roots: roots, facts: facts,
                             paidPlans: paid,
                             singlePoint: try singlePoint(snapshotID: snapshotID, limit: singlePointLimit, in: db))
    }

    // MARK: - SQL

    static let graded = "f.provider NOT IN ('\(ScanRoot.backupProvider)', '\(ScanRoot.unrecognizedProvider)')"

    static let dropGradeTables = """
        DROP TABLE IF EXISTS temp.grade_files; DROP TABLE IF EXISTS temp.grade_keys;
        DROP TABLE IF EXISTS temp.grade_names; DROP TABLE IF EXISTS temp.grade_locs;
        DROP TABLE IF EXISTS temp.single_point;
        """

    /// Builds the graded files, the downloaded-file keys with their location bits, and the
    /// name-and-size masks per backup.
    static func buildGradeTables(scope: String, masked: [String], in db: SQLiteConnection) throws {
        try db.execute(dropGradeTables + """
            CREATE TEMP TABLE grade_locs (root_id TEXT PRIMARY KEY, bit INTEGER NOT NULL);
            CREATE TEMP TABLE grade_files AS
                SELECT f.rowid AS rid, f.root_id, f.provider, f.top_level, f.search_name, f.logical_size,
                    f.modified_at, f.sha256, f.is_placeholder
                FROM files f WHERE \(scope) AND \(graded) AND f.logical_size > 0;
            CREATE TEMP TABLE grade_keys (search_name TEXT, logical_size INTEGER, modified_at REAL,
                bit INTEGER, sha256 TEXT, root_id TEXT);
            """)
        let loc = try db.prepare("INSERT INTO temp.grade_locs (root_id, bit) VALUES (?1, ?2)")
        for (index, backup) in masked.enumerated() {
            loc.reset()
            loc.bind(1, backup)
            loc.bind(2, Int64(1) << Int64(index + 1))
            try loc.step()
        }
        // Downloaded, non-empty files with a date: bit 1 for any sync folder on this Mac, the
        // backup's bit for a backup root (0 for backups past the mask, which use their own pass).
        try db.execute("""
            INSERT INTO temp.grade_keys
            SELECT f.search_name, f.logical_size, f.modified_at,
                CASE WHEN f.provider = '\(ScanRoot.backupProvider)'
                     THEN COALESCE((SELECT l.bit FROM temp.grade_locs l WHERE l.root_id = f.root_id), 0)
                     ELSE 1 END,
                f.sha256, f.root_id
            FROM files f
            WHERE \(scope) AND f.is_placeholder = 0 AND f.logical_size > 0 AND f.modified_at IS NOT NULL;
            CREATE INDEX temp.grade_keys_any ON grade_keys (search_name, logical_size, modified_at, bit, sha256);
            CREATE INDEX temp.grade_keys_root ON grade_keys (search_name, logical_size, root_id, modified_at, sha256);
            CREATE TEMP TABLE grade_names AS
                SELECT search_name, logical_size, SUM(DISTINCT bit) AS bits FROM grade_keys WHERE bit > 1
                GROUP BY search_name, logical_size;
            CREATE INDEX temp.grade_names_key ON grade_names (search_name, logical_size);
            ANALYZE temp;
            """)
    }

    /// When both files were hashed, the hashes must agree: a different SHA-256 overrides a
    /// name, size and date match.
    static let hashesAgree = "(k.sha256 IS NULL OR g.sha256 IS NULL OR k.sha256 = g.sha256)"

    static let window = "k.modified_at BETWEEN g.modified_at - \(matchWindow) AND g.modified_at + \(matchWindow)"

    /// One row per folder and combination of location masks.
    static let passSQL = """
        SELECT root_id, provider, top_level, local, strong, near, COUNT(*), SUM(logical_size)
        FROM (
            SELECT g.root_id, g.provider, g.top_level, g.logical_size,
                COALESCE(strong, 0) AS strong, COALESCE(near, 0) AS near,
                (g.is_placeholder = 0 OR COALESCE(strong, 0) & 1) AS local
            FROM (
                SELECT g.*,
                    (SELECT SUM(DISTINCT k.bit) FROM temp.grade_keys k
                     WHERE k.search_name = g.search_name AND k.logical_size = g.logical_size
                         AND \(window) AND \(hashesAgree)) AS strong,
                    (SELECT n.bits FROM temp.grade_names n
                     WHERE n.search_name = g.search_name AND n.logical_size = g.logical_size) AS near
                FROM temp.grade_files g) g)
        GROUP BY root_id, top_level, local, strong, near
        """

    /// For a backup past the mask: files it holds, and files matching it by name and size only.
    static let overflowSQL = """
        SELECT root_id, top_level, SUM(strong), SUM(CASE WHEN strong THEN logical_size ELSE 0 END),
            SUM(1 - strong), SUM(CASE WHEN strong THEN 0 ELSE logical_size END)
        FROM (
            SELECT g.root_id, g.top_level, g.logical_size,
                EXISTS (SELECT 1 FROM temp.grade_keys k
                        WHERE k.search_name = g.search_name AND k.logical_size = g.logical_size
                            AND k.root_id = ?1 AND \(window) AND \(hashesAgree)) AS strong
            FROM temp.grade_files g
            WHERE EXISTS (SELECT 1 FROM temp.grade_keys k
                          WHERE k.search_name = g.search_name AND k.logical_size = g.logical_size AND k.root_id = ?1))
        GROUP BY root_id, top_level
        """

    /// Placeholders with no downloaded copy anywhere Cloudpane looked. Another cloud's
    /// placeholder is not a copy. The matching runs once, into a temporary table of row ids
    /// and sizes; the totals and the largest files both come from that table.
    static let singlePointSQL = """
        INSERT INTO temp.single_point
        SELECT g.rid, g.logical_size FROM temp.grade_files g
        WHERE g.is_placeholder = 1
            AND NOT EXISTS (SELECT 1 FROM temp.grade_keys k
                WHERE k.search_name = g.search_name AND k.logical_size = g.logical_size
                    AND \(window) AND \(hashesAgree))
        """

    private static func singlePoint(snapshotID: Int64, limit: Int, in db: SQLiteConnection) throws -> SinglePointList {
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS single_point (rid INTEGER, size INTEGER); DELETE FROM temp.single_point;")
        try db.execute(singlePointSQL)
        let totals = try db.prepare("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM temp.single_point")
        _ = try totals.step()
        let list = try db.prepare("""
            SELECT \(Inventory.fileColumns(prefix: "f")) FROM temp.single_point s
            JOIN files f ON f.rowid = s.rid
            ORDER BY s.size DESC, f.path LIMIT ?
            """)
        list.bind(1, limit)
        var files: [FileRecord] = []
        while try list.step() { files.append(Inventory.readFile(list, snapshot: snapshotID)) }
        return SinglePointList(files: files, totalFiles: totals.int(0), totalBytes: totals.int64(1))
    }

    /// EXPLAIN QUERY PLAN for each grading query, for tests that guard against a full scan
    /// of the key tables returning.
    func gradeQueryPlans(snapshotID: Int64) throws -> [String: [String]] {
        let scope = try rows(of: snapshotID)
        let backups = try rootSummaries(snapshotID: snapshotID).map(\.root).filter { $0.kind == .backup }.map(\.id)
        try Inventory.buildGradeTables(scope: scope, masked: backups, in: db)
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS single_point (rid INTEGER, size INTEGER)")
        defer { try? db.execute(Inventory.dropGradeTables) }
        var plans: [String: [String]] = [:]
        for (name, sql) in [("pass", Inventory.passSQL), ("overflow", Inventory.overflowSQL),
                            ("singlePoint", Inventory.singlePointSQL)] {
            let statement = try db.prepare("EXPLAIN QUERY PLAN " + sql)
            var lines: [String] = []
            while try statement.step() { lines.append(statement.string(3) ?? "") }
            plans[name] = lines
        }
        return plans
    }
}
