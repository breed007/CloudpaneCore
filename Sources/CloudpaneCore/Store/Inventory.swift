import Foundation

public enum SnapshotStatus: String, Sendable, Hashable, Codable {
    case running
    case complete
    case canceled
    case failed
    /// Found still running when the database was opened: the process that wrote it was
    /// killed or crashed mid-scan.
    case interrupted
}

public enum InventoryError: Error, CustomStringConvertible, Sendable {
    case noSuchSnapshot(Int64)
    /// Totals and diffs of a snapshot that did not finish would read as missing files.
    case incompleteSnapshot(Int64, SnapshotStatus)
    /// An older layout this build cannot read. The file is left untouched.
    case unsupportedSchema(Int64)
    /// Written by a newer Cloudpane. The file is left untouched.
    case newerSchema(Int64)

    public var description: String {
        switch self {
        case .noSuchSnapshot(let id):
            return "No snapshot \(id)"
        case .incompleteSnapshot(let id, let status):
            return "Snapshot \(id) is \(status.rawValue), not complete; its totals would be partial"
        case .unsupportedSchema(let version):
            return "This inventory uses schema version \(version), from a pre-release build of Cloudpane, which this version cannot read. Cloudpane left it as it is."
        case .newerSchema(let version):
            return "This inventory was written by a newer version of Cloudpane (schema version \(version)). Update Cloudpane to open it. Cloudpane left it as it is."
        }
    }
}

public struct Snapshot: Sendable, Hashable, Codable, Identifiable {
    public let id: Int64
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: SnapshotStatus
    public let homePath: String
    /// The PlaceholderRule id that derived isPlaceholder for this snapshot's files.
    public let placeholderRule: String
    /// True for a snapshot built from watcher changes on top of an earlier one.
    public var isIncremental: Bool = false
}

/// The SQLite store: one database with a snapshots table, per-root totals for each
/// snapshot, and a files table holding every record. Raw sqlite3; see DECISIONS.md.
public actor Inventory {
    let db: SQLiteConnection
    /// The database path, so grading can open its own read-only connection.
    nonisolated let path: String
    /// Scans and incremental updates run one at a time, in the order they asked. Each takes
    /// the gate before reading anything it builds on, so nothing read before the walk's await
    /// can go stale while another writer runs.
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireWrite() async {
        guard writing else {
            writing = true
            return
        }
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    func releaseWrite() {
        if writeWaiters.isEmpty {
            writing = false
        } else {
            writeWaiters.removeFirst().resume()
        }
    }

    /// Opens or creates the database at path. Pass ":memory:" for a throwaway store.
    ///
    /// Any snapshot still marked running is marked interrupted: one process owns the
    /// database at a time, so a running snapshot at open time belongs to a scan that died.
    public init(path: String) throws {
        self.path = path
        db = try SQLiteConnection(path: path)
        // Check the version before anything that writes: switching to WAL changes the file
        // header, and a database this build cannot read must be left exactly as it was.
        try Inventory.checkVersion(db)
        try db.execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            _ = try? db.execute("PRAGMA journal_mode = WAL")
            // Grading and the totals read the files table several times over. Memory-mapped
            // reads and a 64 MB page cache keep repeat passes off the read() path.
            _ = try? db.execute("PRAGMA mmap_size = 268435456; PRAGMA cache_size = -65536")
        }
        try Inventory.migrate(db)
        try db.execute("UPDATE snapshots SET status = 'interrupted' WHERE status = 'running'")
    }

    static let schemaVersion: Int64 = 9

    /// Brings the database to schemaVersion one step at a time, each step in its own
    /// transaction. Steps only ever add; no step drops or rewrites existing data.
    private static func checkVersion(_ db: SQLiteConnection) throws {
        let version = try db.integerPragma("user_version")
        if version > schemaVersion { throw InventoryError.newerSchema(version) }
        guard [0, 2, 3, 4, 5, 6, 7, 8, schemaVersion].contains(version) else {
            throw InventoryError.unsupportedSchema(version)
        }
    }

    private static func migrate(_ db: SQLiteConnection) throws {
        var version = try db.integerPragma("user_version")
        if version == schemaVersion { return }
        guard [0, 2, 3, 4, 5, 6, 7, 8].contains(version) else { throw InventoryError.unsupportedSchema(version) }
        if version == 0 {
            try db.transaction {
                try db.execute(schemaV2 + "PRAGMA user_version = 2;")
            }
            version = 2
        }
        if version == 2 {
            try db.transaction {
                try db.execute(migrationV3 + "PRAGMA user_version = 3;")
            }
            version = 3
        }
        if version == 3 {
            try db.transaction {
                try db.execute(migrationV4 + "PRAGMA user_version = 4;")
            }
            version = 4
        }
        if version == 4 {
            try db.transaction {
                try db.execute(migrationV5 + "PRAGMA user_version = 5;")
            }
            version = 5
        }
        if version == 5 {
            try db.transaction {
                try db.execute(migrationV6 + "PRAGMA user_version = 6;")
            }
            version = 6
        }
        if version == 6 {
            try db.transaction {
                try db.execute(migrationV7 + "PRAGMA user_version = 7;")
            }
            version = 7
        }
        if version == 7 {
            try db.transaction {
                try db.execute(migrationV8 + "PRAGMA user_version = 8;")
            }
            version = 8
        }
        if version == 8 {
            try db.transaction {
                try db.execute(migrationV9 + "PRAGMA user_version = 9;")
            }
        }
    }

    /// Version 9: what the user chose in Providers. custom_providers are providers the user
    /// added: a cost-only plan (folder_name NULL) or a name for a folder under
    /// Library/CloudStorage (folder_name, unique). Their provider id is "custom-<id>", and
    /// AUTOINCREMENT keeps an id from ever being reused: past snapshots keep rows filed under
    /// a removed provider's id, and a new provider must never take them over.
    /// excluded_roots are account roots scans leave out; forgotten_roots are missing
    /// accounts hidden until found again. Both are keyed by the root's canonical path.
    static let migrationV9 = """
        CREATE TABLE custom_providers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            folder_name TEXT UNIQUE,
            created_at REAL NOT NULL
        );
        CREATE TABLE excluded_roots (
            path TEXT PRIMARY KEY,
            excluded_at REAL NOT NULL
        );
        CREATE TABLE forgotten_roots (
            path TEXT PRIMARY KEY,
            forgotten_at REAL NOT NULL
        );

        """

    /// Version 8: why folders could not be listed, so a partial view names the right cause
    /// (the provider, a permission, a path too long). unlisted_folders stays the total; rows
    /// from version 7 read as "could not be listed" for every cause.
    static let migrationV8 = """
        ALTER TABLE snapshot_roots ADD COLUMN unlisted_not_provided INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE snapshot_roots ADD COLUMN unlisted_permission INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE snapshot_roots ADD COLUMN unlisted_path_too_long INTEGER NOT NULL DEFAULT 0;

        """

    /// Version 7: folders a scan could not list, per root (the folder-listing rule). A root
    /// with any is a partial view. Older scans read as 0: the enumerator walk did not count
    /// them separately.
    static let migrationV7 = """
        ALTER TABLE snapshot_roots ADD COLUMN unlisted_folders INTEGER NOT NULL DEFAULT 0;

        """

    /// Version 6 (M5): figures for the iCloud plan that a scan cannot read. reported_usage
    /// holds an account total the user typed in from System Settings, one per provider.
    /// photos_library holds the one Photos library the user chose, its read-only bookmark,
    /// and the last estimate measured from it (NULL until measured).
    static let migrationV6 = """
        CREATE TABLE reported_usage (
            provider TEXT PRIMARY KEY,
            bytes INTEGER NOT NULL,
            entered_at REAL NOT NULL
        );
        CREATE TABLE photos_library (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            path TEXT NOT NULL,
            bookmark BLOB NOT NULL,
            logical_bytes INTEGER,
            allocated_bytes INTEGER,
            file_count INTEGER,
            dataless_count INTEGER,
            unreadable_count INTEGER,
            measured_at REAL
        );

        """

    /// Version 5: the inode change time joins the facts that decide whether a file changed,
    /// because an edit that keeps the size and restores the modification date (touch -r,
    /// rsync --inplace -t) changes nothing else, and only the system sets it. Indexes serve
    /// hard-link checks and hash lookups on current versions.
    static let migrationV5 = """
        ALTER TABLE files ADD COLUMN ctime REAL;
        CREATE INDEX files_open_inode ON files (root_id, inode) WHERE last_snapshot IS NULL AND staged = 0;
        CREATE INDEX files_open_sha ON files (sha256) WHERE last_snapshot IS NULL AND staged = 0 AND sha256 IS NOT NULL;

        """

    /// Version 4 (M4): file rows become versions. A row is valid from the snapshot in
    /// snapshot_id (the first one that recorded it) through last_snapshot, or still current
    /// when last_snapshot is NULL. Rows a scan is still writing, or that belong to a scan that
    /// never completed, are staged and visible only to that scan. An unchanged file is never
    /// written again, so snapshots cost only what changed. Existing rows keep their meaning:
    /// the latest complete snapshot's rows become the current versions, other complete
    /// snapshots' rows are valid for exactly their own snapshot, and rows of incomplete scans
    /// are staged.
    static let migrationV4 = """
        ALTER TABLE files ADD COLUMN last_snapshot INTEGER;
        ALTER TABLE files ADD COLUMN staged INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE files ADD COLUMN inode INTEGER;
        UPDATE files SET staged = 1
            WHERE snapshot_id IN (SELECT id FROM snapshots WHERE status != 'complete');
        UPDATE files SET last_snapshot = snapshot_id
            WHERE staged = 0
                AND snapshot_id IS NOT (SELECT MAX(id) FROM snapshots WHERE status = 'complete');
        ALTER TABLE snapshots ADD COLUMN kind TEXT NOT NULL DEFAULT 'full';
        ALTER TABLE snapshots ADD COLUMN base_snapshot INTEGER;
        DROP INDEX IF EXISTS files_by_root;
        DROP INDEX IF EXISTS files_by_name;
        DROP INDEX IF EXISTS files_by_key;
        CREATE INDEX files_open_path ON files (path) WHERE last_snapshot IS NULL AND staged = 0;
        CREATE INDEX files_open_root ON files (root_id, top_level) WHERE last_snapshot IS NULL AND staged = 0;
        CREATE INDEX files_open_key ON files (search_name, logical_size) WHERE last_snapshot IS NULL AND staged = 0;
        CREATE INDEX files_closed ON files (last_snapshot) WHERE last_snapshot IS NOT NULL;
        CREATE TABLE hash_folders (
            root_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            added_at REAL NOT NULL,
            PRIMARY KEY (root_id, folder)
        );

        """

    // MARK: - Which rows belong to a snapshot

    /// The SQL condition selecting one snapshot's rows from files, for table alias a.
    /// The latest complete snapshot is exactly the current versions, which the partial
    /// indexes serve; an older complete snapshot is the versions valid at it; a scan that
    /// never completed sees only its own staged rows.
    static func rows(of id: Int64, alias a: String = "f", in db: SQLiteConnection) throws -> String {
        guard let snapshot = try snapshot(id, in: db) else { throw InventoryError.noSuchSnapshot(id) }
        guard snapshot.status == .complete else {
            return "\(a).staged = 1 AND \(a).snapshot_id = \(id)"
        }
        let latest = try db.prepare("SELECT MAX(id) FROM snapshots WHERE status = 'complete'")
        _ = try latest.step()
        if latest.int64OrNil(0) == id {
            return "\(a).staged = 0 AND \(a).last_snapshot IS NULL"
        }
        return "\(a).staged = 0 AND \(a).snapshot_id <= \(id) AND (\(a).last_snapshot IS NULL OR \(a).last_snapshot >= \(id))"
    }

    func rows(of id: Int64, alias: String = "f") throws -> String {
        try Inventory.rows(of: id, alias: alias, in: db)
    }

    /// Schema version 2 exactly as M2 shipped it. Frozen: never edit this; add a migration.
    static let schemaV2 = """
                CREATE TABLE snapshots (
                    id INTEGER PRIMARY KEY,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    status TEXT NOT NULL,
                    home_path TEXT NOT NULL,
                    placeholder_rule TEXT NOT NULL
                );
                CREATE TABLE snapshot_roots (
                    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    root_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    provider_name TEXT NOT NULL,
                    name TEXT NOT NULL,
                    account TEXT,
                    path TEXT NOT NULL,
                    top_level_depth INTEGER NOT NULL,
                    files INTEGER NOT NULL,
                    packages INTEGER NOT NULL,
                    directories INTEGER NOT NULL,
                    dataless_directories INTEGER NOT NULL,
                    logical_bytes INTEGER NOT NULL,
                    allocated_bytes INTEGER NOT NULL,
                    placeholders INTEGER NOT NULL,
                    placeholder_bytes INTEGER NOT NULL,
                    dataless INTEGER NOT NULL,
                    compressed INTEGER NOT NULL,
                    zero_byte INTEGER NOT NULL,
                    hard_links_skipped INTEGER NOT NULL,
                    symlinks_skipped INTEGER NOT NULL,
                    other_types_skipped INTEGER NOT NULL,
                    nested_roots_skipped INTEGER NOT NULL,
                    errors INTEGER NOT NULL,
                    package_logical_bytes INTEGER NOT NULL,
                    package_allocated_bytes INTEGER NOT NULL,
                    elapsed_ms REAL NOT NULL,
                    interrupted INTEGER NOT NULL,
                    PRIMARY KEY (snapshot_id, root_id)
                );
                CREATE TABLE files (
                    snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    root_id TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    name TEXT NOT NULL,
                    search_name TEXT NOT NULL,
                    search_path TEXT NOT NULL,
                    top_level TEXT NOT NULL,
                    logical_size INTEGER,
                    allocated_size INTEGER,
                    modified_at REAL,
                    is_ubiquitous INTEGER NOT NULL,
                    download_status TEXT NOT NULL,
                    is_dataless INTEGER NOT NULL,
                    is_compressed INTEGER NOT NULL,
                    is_package INTEGER NOT NULL,
                    is_placeholder INTEGER NOT NULL,
                    content_type TEXT,
                    category TEXT NOT NULL,
                    sha256 TEXT,
                    PRIMARY KEY (snapshot_id, path)
                );
                CREATE INDEX files_by_root ON files (snapshot_id, root_id, top_level);
                CREATE INDEX files_by_name ON files (snapshot_id, name);
        """

    /// Version 3 (M3): subscriptions, backup locations, how each backup root was labeled
    /// in a scan, and an index for matching files across locations by name and size.
    static let migrationV3 = """
        CREATE TABLE subscriptions (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            price TEXT NOT NULL,
            currency TEXT NOT NULL,
            cycle TEXT NOT NULL,
            frequency INTEGER NOT NULL,
            next_payment REAL,
            payment_method TEXT NOT NULL,
            category TEXT NOT NULL,
            url TEXT NOT NULL,
            notes TEXT NOT NULL,
            auto_renew INTEGER NOT NULL,
            inactive INTEGER NOT NULL,
            plan_bytes INTEGER,
            bundle TEXT,
            updated_at REAL NOT NULL
        );
        CREATE TABLE backup_locations (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            label TEXT NOT NULL,
            kind TEXT NOT NULL,
            offsite INTEGER NOT NULL,
            bookmark BLOB NOT NULL,
            added_at REAL NOT NULL
        );
        ALTER TABLE snapshot_roots ADD COLUMN backup_kind TEXT;
        ALTER TABLE snapshot_roots ADD COLUMN offsite INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX files_by_key ON files (snapshot_id, search_name, logical_size);

        """

    // MARK: - Writing

    /// Creates a snapshot in the running state and returns its id.
    public func beginSnapshot(homePath: String, placeholderRule: String,
                              startedAt: Date = Date()) throws -> Int64 {
        try beginSnapshot(homePath: homePath, placeholderRule: placeholderRule, startedAt: startedAt,
                          kind: "full", base: nil)
    }

    func beginSnapshot(homePath: String, placeholderRule: String, startedAt: Date, kind: String,
                       base: Int64?) throws -> Int64 {
        // A new scan replaces any unfinished one: drop the staged rows canceled, failed or
        // interrupted scans left behind, so repeated cancels cannot grow the database. Their
        // snapshot records stay. SQLite reuses the freed pages.
        try db.execute("""
            DELETE FROM files WHERE staged = 1
                AND snapshot_id IN (SELECT id FROM snapshots WHERE status != 'complete')
            """)
        let statement = try db.prepare("""
            INSERT INTO snapshots (started_at, status, home_path, placeholder_rule, kind, base_snapshot)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        statement.bind(1, startedAt)
        statement.bind(2, SnapshotStatus.running.rawValue)
        statement.bind(3, homePath)
        statement.bind(4, placeholderRule)
        statement.bind(5, kind)
        statement.bind(6, base)
        try statement.step()
        return db.lastInsertRowID
    }

    /// Records how a scan ended. Completing a full scan merges its staged rows into the
    /// current versions in one transaction: rows equal to the current version are dropped,
    /// changed and vanished files close their old version, and the rest become current.
    public func finishSnapshot(_ id: Int64, status: SnapshotStatus, finishedAt: Date = Date()) throws {
        try db.transaction {
            if status == .complete { try merge(id, scope: nil) }
            let statement = try db.prepare("UPDATE snapshots SET status = ?, finished_at = ? WHERE id = ?")
            statement.bind(1, status.rawValue)
            statement.bind(2, finishedAt)
            statement.bind(3, id)
            try statement.step()
        }
    }

    /// A part of the tree a scan looked at: one path, and everything below it when subtree.
    public struct ScopeEntry: Sendable, Hashable {
        public let path: String
        public let subtree: Bool
        public init(path: String, subtree: Bool = true) {
            self.path = path
            self.subtree = subtree
        }
    }

    /// Facts compared to decide that a staged row is the same file as the current version.
    static let sameVersion = """
        o.logical_size IS s.logical_size AND o.allocated_size IS s.allocated_size
            AND o.modified_at IS s.modified_at AND o.is_placeholder = s.is_placeholder
            AND o.is_dataless = s.is_dataless AND o.is_compressed = s.is_compressed
            AND o.download_status = s.download_status AND o.is_ubiquitous = s.is_ubiquitous
            AND o.is_package = s.is_package AND o.inode IS s.inode AND o.root_id = s.root_id
            AND (o.ctime IS s.ctime OR (o.ctime IS NULL AND o.sha256 IS NULL))
            AND o.top_level = s.top_level AND o.content_type IS s.content_type
            AND o.category = s.category AND o.sha256 IS s.sha256
        """

    /// Merges snapshot id's staged rows into the current versions. scope nil means a full
    /// scan: every current version not seen again is closed. With a scope, only current
    /// versions inside it can close; everything else carries forward untouched.
    func merge(_ id: Int64, scope: [ScopeEntry]?) throws {
        let base = try db.prepare("SELECT MAX(id) FROM snapshots WHERE status = 'complete' AND id < ?")
        base.bind(1, id)
        _ = try base.step()
        let closeAt = base.int64OrNil(0) ?? id - 1

        // A hash survives a version change as long as size, date and inode do.
        let carry = try db.prepare("""
            UPDATE files AS s SET sha256 = o.sha256
            FROM files AS o INDEXED BY files_open_path
            WHERE s.snapshot_id = ?1 AND s.staged = 1 AND s.sha256 IS NULL
                AND o.path = s.path AND o.staged = 0 AND o.last_snapshot IS NULL AND o.sha256 IS NOT NULL
                AND o.logical_size IS s.logical_size AND o.modified_at IS s.modified_at AND o.inode IS s.inode
                AND o.ctime IS s.ctime
            """)
        carry.bind(1, id)
        try carry.step()

        // Kept for the connection's life and emptied each time: dropping a table while a
        // prepared statement still refers to it fails with SQLITE_LOCKED.
        try db.execute("""
            CREATE TEMP TABLE IF NOT EXISTS unchanged (path TEXT PRIMARY KEY);
            DELETE FROM temp.unchanged;
            """)
        defer { try? db.execute("DELETE FROM temp.unchanged") }
        // INDEXED BY: the equality on root and top-level folder otherwise tempts the
        // planner onto files_open_root, a thousand candidates per lookup instead of one
        // (21 s instead of 0.13 s for 100,000 files, measured).
        let unchanged = try db.prepare("""
            INSERT INTO temp.unchanged
            SELECT s.path FROM files s JOIN files o INDEXED BY files_open_path ON o.path = s.path
            WHERE s.snapshot_id = ?1 AND s.staged = 1
                AND o.staged = 0 AND o.last_snapshot IS NULL AND o.snapshot_id < ?1
                AND \(Inventory.sameVersion)
            """)
        unchanged.bind(1, id)
        try unchanged.step()

        let notUnchanged = "staged = 0 AND last_snapshot IS NULL AND snapshot_id < ?1 AND path NOT IN (SELECT path FROM temp.unchanged)"
        if let scope {
            for entry in scope {
                let close = try db.prepare("""
                    UPDATE files INDEXED BY files_open_path SET last_snapshot = ?2
                    WHERE \(notUnchanged)
                        AND (path = ?3 OR (?4 AND path > ?3 || '/' AND path < ?3 || '0'))
                    """)
                close.bind(1, id)
                close.bind(2, closeAt)
                close.bind(3, entry.path)
                close.bind(4, entry.subtree)
                try close.step()
            }
        } else {
            let close = try db.prepare("UPDATE files SET last_snapshot = ?2 WHERE \(notUnchanged)")
            close.bind(1, id)
            close.bind(2, closeAt)
            try close.step()
        }

        // Rows from before version 5 have no inode change time; fill it in once confirmed.
        let backfill = try db.prepare("""
            UPDATE files AS o SET ctime = s.ctime
            FROM files AS s
            WHERE o.staged = 0 AND o.last_snapshot IS NULL AND o.ctime IS NULL
                AND o.path IN (SELECT path FROM temp.unchanged)
                AND s.snapshot_id = ?1 AND s.staged = 1 AND s.path = o.path
            """)
        backfill.bind(1, id)
        try backfill.step()

        // A new hard link to a file already recorded in the same root is not a second file.
        // Runs after closing, so a full scan that no longer saw the first path keeps the link.
        let links = try db.prepare("""
            DELETE FROM files WHERE snapshot_id = ?1 AND staged = 1 AND inode IS NOT NULL
                AND EXISTS (SELECT 1 FROM files o INDEXED BY files_open_inode
                            WHERE o.root_id = files.root_id AND o.inode = files.inode
                                AND o.staged = 0 AND o.last_snapshot IS NULL AND o.path != files.path)
            """)
        links.bind(1, id)
        try links.step()

        let drop = try db.prepare("""
            DELETE FROM files WHERE snapshot_id = ?1 AND staged = 1 AND path IN (SELECT path FROM temp.unchanged)
            """)
        drop.bind(1, id)
        try drop.step()
        let commit = try db.prepare("UPDATE files SET staged = 0 WHERE snapshot_id = ?1 AND staged = 1")
        commit.bind(1, id)
        try commit.step()
    }

    /// Writes a batch of records in one transaction with one prepared statement.
    public func insert(_ records: [FileRecord]) throws {
        guard !records.isEmpty else { return }
        try db.transaction {
            let statement = try db.prepare("""
                INSERT INTO files (snapshot_id, path, root_id, provider, relative_path, name,
                    top_level, logical_size, allocated_size, modified_at, is_ubiquitous,
                    download_status, is_dataless, is_compressed, is_package, is_placeholder,
                    content_type, category, sha256, search_name, search_path, inode, ctime, staged)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                """)
            for record in records {
                statement.reset()
                statement.bind(1, record.snapshotID)
                statement.bind(2, record.path)
                statement.bind(3, record.rootID)
                statement.bind(4, record.provider)
                statement.bind(5, record.relativePath)
                statement.bind(6, record.name)
                statement.bind(7, record.topLevelFolder)
                statement.bind(8, record.logicalSize)
                statement.bind(9, record.allocatedSize)
                statement.bind(10, record.modified)
                statement.bind(11, record.isUbiquitous)
                statement.bind(12, record.downloadStatus.rawValue)
                statement.bind(13, record.isDataless)
                statement.bind(14, record.isCompressed)
                statement.bind(15, record.isPackage)
                statement.bind(16, record.isPlaceholder)
                statement.bind(17, record.contentType)
                statement.bind(18, record.category.rawValue)
                statement.bind(19, record.sha256)
                statement.bind(20, SearchKey.make(record.name))
                statement.bind(21, SearchKey.make(record.path))
                statement.bind(22, record.inode.map { Int64(bitPattern: $0) })
                statement.bind(23, record.statusChanged)
                try statement.step()
            }
        }
    }

    public func insert(_ summary: RootSummary, snapshotID: Int64, position: Int) throws {
        let statement = try db.prepare("""
            INSERT INTO snapshot_roots (snapshot_id, position, root_id, kind, provider,
                provider_name, name, account, path, top_level_depth, files, packages,
                directories, dataless_directories, logical_bytes, allocated_bytes, placeholders,
                placeholder_bytes, dataless, compressed, zero_byte, hard_links_skipped,
                symlinks_skipped, other_types_skipped, nested_roots_skipped, errors,
                package_logical_bytes, package_allocated_bytes, elapsed_ms, interrupted,
                backup_kind, offsite, unlisted_folders, unlisted_not_provided, unlisted_permission,
                unlisted_path_too_long)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let root = summary.root
        let values: [Int64] = [
            Int64(summary.files), Int64(summary.packages), Int64(summary.directories),
            Int64(summary.datalessDirectories), summary.logicalBytes, summary.allocatedBytes,
            Int64(summary.placeholders), summary.placeholderBytes, Int64(summary.dataless),
            Int64(summary.compressed), Int64(summary.zeroByte), Int64(summary.hardLinksSkipped),
            Int64(summary.symlinksSkipped), Int64(summary.otherTypesSkipped),
            Int64(summary.nestedRootsSkipped), Int64(summary.errors),
            summary.packageLogicalBytes, summary.packageAllocatedBytes,
        ]
        statement.bind(1, snapshotID)
        statement.bind(2, position)
        statement.bind(3, root.id)
        statement.bind(4, root.kind.rawValue)
        statement.bind(5, root.provider)
        statement.bind(6, root.providerName)
        statement.bind(7, root.name)
        statement.bind(8, root.account)
        statement.bind(9, root.path)
        statement.bind(10, root.topLevelDepth)
        for (offset, value) in values.enumerated() {
            statement.bind(Int32(11 + offset), value)
        }
        statement.bind(29, summary.elapsedMilliseconds)
        statement.bind(30, summary.wasInterrupted)
        statement.bind(31, root.backupKind?.rawValue)
        statement.bind(32, root.isOffsite)
        statement.bind(33, summary.unlistedFolders)
        statement.bind(34, summary.unlistedNotProvided)
        statement.bind(35, summary.unlistedPermission)
        statement.bind(36, summary.unlistedPathTooLong)
        try statement.step()
    }

    /// Runs a scan and records it as a new snapshot, writing files in batches.
    ///
    /// Canceling the calling task cancels the walk; the snapshot is then marked canceled and
    /// keeps what was written. The root being walked at that moment gets a root row built
    /// from the records that arrived, flagged as interrupted, so the files table and the
    /// root rows always agree. Its skip counts are unknown and stay 0. A write error stops
    /// the walk, marks the snapshot failed, and is rethrown.
    @discardableResult
    public func recordScan(_ scanner: Scanner, homePath: String, batchSize: Int = 1_000,
                           onEvent: (@Sendable (ScanEvent) -> Void)? = nil) async throws -> Int64 {
        await acquireWrite()
        defer { releaseWrite() }
        let id = try beginSnapshot(homePath: homePath, placeholderRule: scanner.placeholderRule.id)
        var batch: [FileRecord] = []
        batch.reserveCapacity(batchSize)
        var finished: ScanSummary?
        var position = 0
        // Built from the events, in case the walk is canceled before it reports this root.
        var current: RootSummary?
        do {
            for await event in scanner.scan(snapshotID: id) {
                onEvent?(event)
                switch event {
                case .rootStarted(let root):
                    current = RootSummary(root: root)
                case .file(let record):
                    current?.add(record)
                    batch.append(record)
                    if batch.count >= batchSize {
                        try insert(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                case .issue:
                    current?.errors += 1
                case .rootFinished(let summary):
                    try insert(batch)
                    batch.removeAll(keepingCapacity: true)
                    try insert(summary, snapshotID: id, position: position)
                    position += 1
                    current = nil
                case .finished(let summary):
                    finished = summary
                case .progress:
                    break
                }
            }
            try insert(batch)
            if var partial = current {
                partial.wasInterrupted = true
                try insert(partial, snapshotID: id, position: position)
            }
        } catch {
            try? finishSnapshot(id, status: .failed)
            throw error
        }
        let status: SnapshotStatus = (finished == nil || finished?.wasCanceled == true) ? .canceled : .complete
        try finishSnapshot(id, status: status)
        return id
    }
}
