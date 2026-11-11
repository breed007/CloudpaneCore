import Foundation

public struct ProviderTotal: Sendable, Hashable, Codable {
    public let provider: String
    public let providerName: String
    public let roots: Int
    public let files: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let placeholders: Int
    public let placeholderBytes: Int64
}

public struct FolderTotal: Sendable, Hashable, Codable {
    public let provider: String
    public let rootID: String
    /// Empty for items directly in the root.
    public let folder: String
    public let files: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let placeholders: Int
    public let placeholderBytes: Int64
}

public struct TypeTotal: Sendable, Hashable, Codable {
    /// A FileCategory raw value or a UTType identifier, depending on the grouping.
    /// "unknown" when no content type was reported.
    public let key: String
    public let files: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
}

public enum TypeGrouping: Sendable {
    case category
    case contentType
}

public enum SearchField: Sendable {
    /// The file or package name only.
    case name
    /// The full path, so folder names match too.
    case path
}

public struct SnapshotDiff: Sendable, Hashable {
    public struct ChangeKinds: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let size = ChangeKinds(rawValue: 1)
        public static let modified = ChangeKinds(rawValue: 2)
        /// Went from placeholder to materialized or back.
        public static let placeholder = ChangeKinds(rawValue: 4)
    }

    public struct Change: Sendable, Hashable {
        public let before: FileRecord
        public let after: FileRecord
        public let kinds: ChangeKinds
    }

    public let fromSnapshot: Int64
    public let toSnapshot: Int64
    /// Counts and byte totals always cover the whole diff, whatever the list limit.
    public let addedCount: Int
    public let removedCount: Int
    public let changedCount: Int
    public let addedBytes: Int64
    public let removedBytes: Int64
    /// Sum of (new logical size - old logical size) over changed items.
    public let changedByteDelta: Int64
    public let added: [FileRecord]
    public let removed: [FileRecord]
    public let changed: [Change]

    /// A file that left one path and appeared at another: the same name, size and date
    /// (within 2 seconds), or the same SHA-256 when both versions were hashed.
    public struct Move: Sendable, Hashable {
        public let before: FileRecord
        public let after: FileRecord
        public let matchedByHash: Bool
    }

    /// Moves are taken out of added and removed, and counted here.
    public let movedCount: Int
    public let moved: [Move]
}

extension Inventory {
    static let fileColumns = """
        snapshot_id, path, root_id, provider, relative_path, name, top_level, logical_size,
        allocated_size, modified_at, is_ubiquitous, download_status, is_dataless, is_compressed,
        is_package, is_placeholder, content_type, category, sha256, inode, ctime
        """

    /// Number of columns in fileColumns, for reading two records from one row.
    static let fileColumnCount: Int32 = 21

    static func fileColumns(prefix: String) -> String {
        fileColumns.split(separator: ",")
            .map { "\(prefix).\($0.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: ", ")
    }

    /// Reads a FileRecord from 19 columns in fileColumns order, starting at offset.
    /// A row is a version that can span many snapshots, so pass the snapshot being read to
    /// report it rather than the snapshot that first recorded the version.
    static func readFile(_ s: SQLiteStatement, at offset: Int32 = 0, snapshot: Int64? = nil) -> FileRecord {
        let o = offset
        let facts = FileFacts(
            logicalSize: s.int64OrNil(o + 7), allocatedSize: s.int64OrNil(o + 8),
            isUbiquitous: s.bool(o + 10),
            downloadStatus: DownloadStatus(rawValue: s.string(o + 11) ?? "") ?? .none,
            isDataless: s.bool(o + 12), isCompressed: s.bool(o + 13))
        return FileRecord(
            snapshotID: snapshot ?? s.int64(o), path: s.string(o + 1) ?? "", rootID: s.string(o + 2) ?? "",
            provider: s.string(o + 3) ?? "", relativePath: s.string(o + 4) ?? "",
            name: s.string(o + 5) ?? "", topLevelFolder: s.string(o + 6) ?? "", facts: facts,
            modified: s.dateOrNil(o + 9), isPackage: s.bool(o + 14), isPlaceholder: s.bool(o + 15),
            contentType: s.string(o + 16),
            category: FileCategory(rawValue: s.string(o + 17) ?? "") ?? .other,
            sha256: s.string(o + 18), inode: s.int64OrNil(o + 19).map { UInt64(bitPattern: $0) },
            statusChanged: s.dateOrNil(o + 20))
    }

    // MARK: - Snapshots

    public func snapshots() throws -> [Snapshot] {
        let statement = try db.prepare("""
            SELECT id, started_at, finished_at, status, home_path, placeholder_rule, kind
            FROM snapshots ORDER BY id
            """)
        var result: [Snapshot] = []
        while try statement.step() { result.append(Inventory.readSnapshot(statement)) }
        return result
    }

    public func snapshot(_ id: Int64) throws -> Snapshot? { try Inventory.snapshot(id, in: db) }

    static func snapshot(_ id: Int64, in db: SQLiteConnection) throws -> Snapshot? {
        let statement = try db.prepare("""
            SELECT id, started_at, finished_at, status, home_path, placeholder_rule, kind
            FROM snapshots WHERE id = ?
            """)
        statement.bind(1, id)
        return try statement.step() ? Inventory.readSnapshot(statement) : nil
    }

    private static func readSnapshot(_ s: SQLiteStatement) -> Snapshot {
        Snapshot(id: s.int64(0), startedAt: s.dateOrNil(1) ?? .distantPast, finishedAt: s.dateOrNil(2),
                 status: SnapshotStatus(rawValue: s.string(3) ?? "") ?? .failed,
                 homePath: s.string(4) ?? "", placeholderRule: s.string(5) ?? "",
                 isIncremental: s.string(6) == "incremental")
    }

    /// Per-root totals as the scanner counted them, in scan order.
    public func rootSummaries(snapshotID: Int64) throws -> [RootSummary] {
        try Inventory.rootSummaries(snapshotID: snapshotID, in: db)
    }

    static func rootSummaries(snapshotID: Int64, in db: SQLiteConnection) throws -> [RootSummary] {
        let statement = try db.prepare("""
            SELECT root_id, kind, provider, provider_name, name, account, path, top_level_depth,
                files, packages, directories, dataless_directories, logical_bytes, allocated_bytes,
                placeholders, placeholder_bytes, dataless, compressed, zero_byte,
                hard_links_skipped, symlinks_skipped, other_types_skipped, nested_roots_skipped,
                errors, package_logical_bytes, package_allocated_bytes, elapsed_ms, interrupted,
                backup_kind, offsite, unlisted_folders, unlisted_not_provided, unlisted_permission,
                unlisted_path_too_long
            FROM snapshot_roots WHERE snapshot_id = ? ORDER BY position
            """)
        statement.bind(1, snapshotID)
        var result: [RootSummary] = []
        while try statement.step() {
            let s = statement
            let root = ScanRoot(id: s.string(0) ?? "",
                                kind: ScanRoot.Kind(rawValue: s.string(1) ?? "") ?? .unrecognized,
                                provider: s.string(2) ?? "", providerName: s.string(3) ?? "",
                                name: s.string(4) ?? "", account: s.string(5), path: s.string(6) ?? "",
                                topLevelDepth: s.int(7),
                                backupKind: s.string(28).flatMap(BackupKind.init(rawValue:)),
                                isOffsite: s.bool(29))
            var summary = RootSummary(root: root)
            summary.files = s.int(8)
            summary.packages = s.int(9)
            summary.directories = s.int(10)
            summary.datalessDirectories = s.int(11)
            summary.logicalBytes = s.int64(12)
            summary.allocatedBytes = s.int64(13)
            summary.placeholders = s.int(14)
            summary.placeholderBytes = s.int64(15)
            summary.dataless = s.int(16)
            summary.compressed = s.int(17)
            summary.zeroByte = s.int(18)
            summary.hardLinksSkipped = s.int(19)
            summary.symlinksSkipped = s.int(20)
            summary.otherTypesSkipped = s.int(21)
            summary.nestedRootsSkipped = s.int(22)
            summary.errors = s.int(23)
            summary.packageLogicalBytes = s.int64(24)
            summary.packageAllocatedBytes = s.int64(25)
            summary.elapsedMilliseconds = s.double(26)
            summary.wasInterrupted = s.bool(27)
            summary.unlistedFolders = s.int(30)
            summary.unlistedNotProvided = s.int(31)
            summary.unlistedPermission = s.int(32)
            summary.unlistedPathTooLong = s.int(33)
            result.append(summary)
        }
        return result
    }

    /// Throws unless the snapshot exists and completed, or the caller accepts partial data.
    func requireComplete(_ id: Int64, allowIncomplete: Bool) throws {
        try Inventory.requireComplete(id, allowIncomplete: allowIncomplete, in: db)
    }

    static func requireComplete(_ id: Int64, allowIncomplete: Bool, in db: SQLiteConnection) throws {
        guard let snapshot = try snapshot(id, in: db) else { throw InventoryError.noSuchSnapshot(id) }
        if !allowIncomplete && snapshot.status != .complete {
            throw InventoryError.incompleteSnapshot(id, snapshot.status)
        }
    }

    // MARK: - Totals
    //
    // Totals, folder totals, the type breakdown and diff refuse a snapshot that did not
    // complete, because missing files would read as files that are gone. Pass
    // allowIncomplete: true to show a canceled or interrupted scan as partial results.

    /// Totals per provider, computed from the files table. Largest first.
    public func providerTotals(snapshotID: Int64, allowIncomplete: Bool = false) throws -> [ProviderTotal] {
        try requireComplete(snapshotID, allowIncomplete: allowIncomplete)
        let statement = try db.prepare("""
            SELECT f.provider,
                COALESCE((SELECT r.provider_name FROM snapshot_roots r
                          WHERE r.snapshot_id = ?1 AND r.provider = f.provider LIMIT 1),
                         f.provider),
                COUNT(DISTINCT f.root_id), COUNT(*),
                COALESCE(SUM(f.logical_size), 0), COALESCE(SUM(f.allocated_size), 0),
                SUM(f.is_placeholder),
                COALESCE(SUM(CASE WHEN f.is_placeholder THEN f.logical_size END), 0)
            FROM files f WHERE \(try rows(of: snapshotID))
            GROUP BY f.provider
            ORDER BY 5 DESC, f.provider
            """)
        statement.bind(1, snapshotID)
        var result: [ProviderTotal] = []
        while try statement.step() {
            let s = statement
            result.append(ProviderTotal(provider: s.string(0) ?? "", providerName: s.string(1) ?? "",
                                        roots: s.int(2), files: s.int(3), logicalBytes: s.int64(4),
                                        allocatedBytes: s.int64(5), placeholders: s.int(6),
                                        placeholderBytes: s.int64(7)))
        }
        return result
    }

    /// Totals per top-level folder, optionally for one provider. Ordered by root, then folder.
    public func folderTotals(snapshotID: Int64, provider: String? = nil,
                             allowIncomplete: Bool = false) throws -> [FolderTotal] {
        try requireComplete(snapshotID, allowIncomplete: allowIncomplete)
        let statement = try db.prepare("""
            SELECT provider, root_id, top_level, COUNT(*),
                COALESCE(SUM(logical_size), 0), COALESCE(SUM(allocated_size), 0),
                SUM(is_placeholder),
                COALESCE(SUM(CASE WHEN is_placeholder THEN logical_size END), 0)
            FROM files f WHERE \(try rows(of: snapshotID)) AND (?2 IS NULL OR provider = ?2)
            GROUP BY provider, root_id, top_level
            ORDER BY root_id, top_level
            """)
        statement.bind(1, snapshotID)
        statement.bind(2, provider)
        var result: [FolderTotal] = []
        while try statement.step() {
            let s = statement
            result.append(FolderTotal(provider: s.string(0) ?? "", rootID: s.string(1) ?? "",
                                      folder: s.string(2) ?? "", files: s.int(3),
                                      logicalBytes: s.int64(4), allocatedBytes: s.int64(5),
                                      placeholders: s.int(6), placeholderBytes: s.int64(7)))
        }
        return result
    }

    /// Totals by file kind or by UTType identifier. Largest first.
    public func typeBreakdown(snapshotID: Int64, grouping: TypeGrouping = .category,
                              allowIncomplete: Bool = false) throws -> [TypeTotal] {
        try requireComplete(snapshotID, allowIncomplete: allowIncomplete)
        let column = grouping == .category ? "category" : "COALESCE(content_type, 'unknown')"
        let statement = try db.prepare("""
            SELECT \(column) AS kind, COUNT(*), COALESCE(SUM(logical_size), 0),
                COALESCE(SUM(allocated_size), 0)
            FROM files f WHERE \(try rows(of: snapshotID))
            GROUP BY kind ORDER BY 3 DESC, kind
            """)
        statement.bind(1, snapshotID)
        var result: [TypeTotal] = []
        while try statement.step() {
            let s = statement
            result.append(TypeTotal(key: s.string(0) ?? "unknown", files: s.int(1),
                                    logicalBytes: s.int64(2), allocatedBytes: s.int64(3)))
        }
        return result
    }

    // MARK: - Search

    /// Literal substring search. Stored names and paths and the query are compared in
    /// SearchKey form (NFC, case-folded beyond ASCII), so "RÉSUMÉ" finds a decomposed
    /// "résumé.pdf". Results carry the exact original name and path. Ordered by path.
    public func search(snapshotID: Int64, text: String, in field: SearchField = .name,
                       limit: Int = 500) throws -> [FileRecord] {
        let column = field == .name ? "search_name" : "search_path"
        let statement = try db.prepare("""
            SELECT \(Inventory.fileColumns(prefix: "f")) FROM files f
            WHERE \(try rows(of: snapshotID)) AND ?1 IS NOT NULL AND instr(f.\(column), ?2) > 0
            ORDER BY f.path LIMIT ?3
            """)
        statement.bind(1, snapshotID)
        statement.bind(2, SearchKey.make(text))
        statement.bind(3, limit)
        var result: [FileRecord] = []
        while try statement.step() { result.append(Inventory.readFile(statement, snapshot: snapshotID)) }
        return result
    }

    // MARK: - Diff

    /// Compares two snapshots. Rows unchanged between them are the same version, so only
    /// versions present in one snapshot and not the other are read. Those pair up by path
    /// into changes (logical size, modification date or placeholder state differ); what is
    /// left pairs into moves where a removed file and an added file share a SHA-256, or a
    /// name, size and date within 2 seconds. The rest is added or removed. limit caps each
    /// list (nil for all); counts and byte totals always cover everything.
    public func diff(from old: Int64, to new: Int64, limit: Int? = nil,
                     allowIncomplete: Bool = false) throws -> SnapshotDiff {
        try requireComplete(old, allowIncomplete: allowIncomplete)
        try requireComplete(new, allowIncomplete: allowIncomplete)
        let oldOnly = try onlyIn(old, notIn: new)
        let newOnly = try onlyIn(new, notIn: old)

        var newByPath = Dictionary(newOnly.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [SnapshotDiff.Change] = []
        var removedCandidates: [FileRecord] = []
        for before in oldOnly {
            guard let after = newByPath.removeValue(forKey: before.path) else {
                removedCandidates.append(before)
                continue
            }
            var kinds: SnapshotDiff.ChangeKinds = []
            if before.logicalSize != after.logicalSize { kinds.insert(.size) }
            if before.modified != after.modified { kinds.insert(.modified) }
            if before.isPlaceholder != after.isPlaceholder { kinds.insert(.placeholder) }
            if !kinds.isEmpty { changed.append(SnapshotDiff.Change(before: before, after: after, kinds: kinds)) }
        }
        var addedCandidates = newByPath.values.sorted { $0.path < $1.path }
        removedCandidates.sort { $0.path < $1.path }

        // Moves: hash matches first, then name, size and date.
        var moved: [SnapshotDiff.Move] = []
        var takenAdded = Set<String>()
        var removedLeft: [FileRecord] = []
        var byHash: [String: [FileRecord]] = [:]
        var byKey: [String: [FileRecord]] = [:]
        for added in addedCandidates {
            if let hash = added.sha256 { byHash[hash, default: []].append(added) }
            byKey[Self.moveKey(added), default: []].append(added)
        }
        for removed in removedCandidates {
            if let hash = removed.sha256,
               let match = byHash[hash]?.first(where: { !takenAdded.contains($0.path) && $0.logicalSize == removed.logicalSize }) {
                takenAdded.insert(match.path)
                moved.append(SnapshotDiff.Move(before: removed, after: match, matchedByHash: true))
                continue
            }
            if let match = byKey[Self.moveKey(removed)]?.first(where: { candidate in
                !takenAdded.contains(candidate.path) && Self.sameDate(candidate.modified, removed.modified)
                    && (candidate.sha256 == nil || removed.sha256 == nil || candidate.sha256 == removed.sha256)
            }) {
                takenAdded.insert(match.path)
                moved.append(SnapshotDiff.Move(before: removed, after: match, matchedByHash: false))
                continue
            }
            removedLeft.append(removed)
        }
        addedCandidates.removeAll { takenAdded.contains($0.path) }
        changed.sort { $0.before.path < $1.before.path }

        func capped<T>(_ items: [T]) -> [T] { limit.map { Array(items.prefix(max($0, 0))) } ?? items }
        let bytes: ([FileRecord]) -> Int64 = { $0.reduce(0) { $0 + ($1.logicalSize ?? 0) } }
        return SnapshotDiff(fromSnapshot: old, toSnapshot: new,
                            addedCount: addedCandidates.count, removedCount: removedLeft.count,
                            changedCount: changed.count, addedBytes: bytes(addedCandidates),
                            removedBytes: bytes(removedLeft),
                            changedByteDelta: changed.reduce(0) { $0 + ($1.after.logicalSize ?? 0) - ($1.before.logicalSize ?? 0) },
                            added: capped(addedCandidates), removed: capped(removedLeft), changed: capped(changed),
                            movedCount: moved.count, moved: capped(moved))
    }

    private static func moveKey(_ record: FileRecord) -> String {
        "\(SearchKey.make(record.name))|\(record.logicalSize ?? -1)"
    }

    private static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) <= Inventory.matchWindow
    }

    /// Versions in snapshot a that are not in snapshot b, as records of snapshot a.
    private func onlyIn(_ a: Int64, notIn b: Int64) throws -> [FileRecord] {
        let statement = try db.prepare("""
            SELECT \(Inventory.fileColumns(prefix: "f")) FROM files f
            WHERE \(try rows(of: a)) AND f.rowid IN (
                SELECT f.rowid FROM files f WHERE \(try rows(of: a))
                EXCEPT
                SELECT f.rowid FROM files f WHERE \(try rows(of: b)))
            """)
        var result: [FileRecord] = []
        while try statement.step() { result.append(Inventory.readFile(statement, snapshot: a)) }
        return result
    }

    /// Calls body for every file in a snapshot, ordered by path, without loading them all.
    func forEachFile(snapshotID: Int64, _ body: (FileRecord) throws -> Void) throws {
        let statement = try db.prepare(
            "SELECT \(Inventory.fileColumns(prefix: "f")) FROM files f WHERE \(try rows(of: snapshotID)) ORDER BY f.path")
        while try statement.step() { try body(Inventory.readFile(statement, snapshot: snapshotID)) }
    }
}
