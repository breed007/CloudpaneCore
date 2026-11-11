import Foundation

/// A top-level folder the user opted in to hashing.
public struct HashFolder: Sendable, Hashable, Identifiable {
    public let rootID: String
    /// Empty for files directly in the root.
    public let folder: String
    public var id: String { "\(rootID)/\(folder)" }

    public init(rootID: String, folder: String) {
        self.rootID = rootID
        self.folder = folder
    }
}

/// What hashing a set of folders will do, counted before anything is read.
public struct HashPlan: Sendable, Hashable {
    public let items: [HashItem]
    public var files: Int { items.count }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
    /// Files only in the cloud: reading them downloads them.
    public let downloadFiles: Int
    public let downloadBytes: Int64
    /// Files already on this Mac: hashed without downloading anything.
    public let localFiles: Int
    public let localBytes: Int64
    /// Files in these folders that already have a current hash and are skipped.
    public let alreadyHashed: Int
}

extension Inventory {
    public func hashFolders() throws -> [HashFolder] {
        let statement = try db.prepare("SELECT root_id, folder FROM hash_folders ORDER BY root_id, folder")
        var result: [HashFolder] = []
        while try statement.step() { result.append(HashFolder(rootID: statement.string(0) ?? "", folder: statement.string(1) ?? "")) }
        return result
    }

    /// Opts a folder in or out. Opting out keeps hashes already stored; they stay valid
    /// until the file changes.
    public func setHashing(_ folder: HashFolder, enabled: Bool) throws {
        let statement = try db.prepare(enabled
            ? "INSERT OR IGNORE INTO hash_folders (root_id, folder, added_at) VALUES (?1, ?2, ?3)"
            : "DELETE FROM hash_folders WHERE root_id = ?1 AND folder = ?2")
        statement.bind(1, folder.rootID)
        statement.bind(2, folder.folder)
        if enabled { statement.bind(3, Date()) }
        try statement.step()
    }

    /// The files in these folders that still need a hash, in the latest complete snapshot,
    /// with exact counts and bytes of what will download. Packages are folders and are
    /// never hashed; empty files are skipped.
    public func hashPlan(for folders: [HashFolder]) throws -> HashPlan {
        let latest = try db.prepare("SELECT MAX(id) FROM snapshots WHERE status = 'complete'")
        _ = try latest.step()
        guard let snapshot = latest.int64OrNil(0) else {
            return HashPlan(items: [], downloadFiles: 0, downloadBytes: 0, localFiles: 0, localBytes: 0, alreadyHashed: 0)
        }
        let scope = try rows(of: snapshot)
        var items: [HashItem] = []
        var downloadFiles = 0, localFiles = 0, alreadyHashed = 0
        var downloadBytes: Int64 = 0, localBytes: Int64 = 0
        for folder in folders {
            let statement = try db.prepare("""
                SELECT f.path, f.logical_size, f.modified_at, f.inode, f.is_placeholder, f.sha256 IS NOT NULL, f.ctime
                FROM files f
                WHERE \(scope) AND f.root_id = ?1 AND f.top_level = ?2 AND f.is_package = 0 AND f.logical_size > 0
                ORDER BY f.path
                """)
            statement.bind(1, folder.rootID)
            statement.bind(2, folder.folder)
            while try statement.step() {
                if statement.bool(5) {
                    alreadyHashed += 1
                    continue
                }
                // A cloud-only file in the plan is the confirmed download; nothing else may download.
                let item = HashItem(path: statement.string(0) ?? "", size: statement.int64(1),
                                    modified: statement.dateOrNil(2),
                                    inode: statement.int64OrNil(3).map { UInt64(bitPattern: $0) },
                                    statusChanged: statement.dateOrNil(6),
                                    isPlaceholder: statement.bool(4), allowDownload: statement.bool(4))
                items.append(item)
                if item.isPlaceholder {
                    downloadFiles += 1
                    downloadBytes += item.size
                } else {
                    localFiles += 1
                    localBytes += item.size
                }
            }
        }
        return HashPlan(items: items, downloadFiles: downloadFiles, downloadBytes: downloadBytes,
                        localFiles: localFiles, localBytes: localBytes, alreadyHashed: alreadyHashed)
    }

    /// Stores hashes, only for files that still have the size, dates and inode they were
    /// read with. A hash is known from the latest complete snapshot on: when the file's
    /// current version began in an earlier snapshot, that version is closed and a copy
    /// carrying the hash begins at the latest one, so earlier snapshots never gain a hash
    /// they did not have. Later snapshots keep it for as long as the file is unchanged.
    public func record(_ results: [HashResult]) throws {
        guard !results.isEmpty else { return }
        let latestQuery = try db.prepare("SELECT MAX(id) FROM snapshots WHERE status = 'complete'")
        _ = try latestQuery.step()
        guard let latest = latestQuery.int64OrNil(0) else { return }
        let previousQuery = try db.prepare("SELECT MAX(id) FROM snapshots WHERE status = 'complete' AND id < ?")
        previousQuery.bind(1, latest)
        _ = try previousQuery.step()
        let closeAt = previousQuery.int64OrNil(0)
        try db.transaction {
            let find = try db.prepare("""
                SELECT rowid, snapshot_id FROM files INDEXED BY files_open_path
                WHERE path = ?1 AND staged = 0 AND last_snapshot IS NULL
                    AND logical_size = ?2 AND modified_at IS ?3 AND inode IS ?4 AND ctime IS ?5
                """)
            let update = try db.prepare("UPDATE files SET sha256 = ?1 WHERE rowid = ?2")
            let copy = try db.prepare("""
                INSERT INTO files (snapshot_id, path, root_id, provider, relative_path, name, search_name,
                    search_path, top_level, logical_size, allocated_size, modified_at, is_ubiquitous,
                    download_status, is_dataless, is_compressed, is_package, is_placeholder, content_type,
                    category, sha256, last_snapshot, staged, inode, ctime)
                SELECT ?1, path, root_id, provider, relative_path, name, search_name, search_path, top_level,
                    logical_size, allocated_size, modified_at, is_ubiquitous, download_status, is_dataless,
                    is_compressed, is_package, is_placeholder, content_type, category, ?2, NULL, 0, inode, ctime
                FROM files WHERE rowid = ?3
                """)
            let close = try db.prepare("UPDATE files SET last_snapshot = ?1 WHERE rowid = ?2")
            for result in results {
                find.reset()
                find.bind(1, result.item.path)
                find.bind(2, result.item.size)
                find.bind(3, result.item.modified)
                find.bind(4, result.item.inode.map { Int64(bitPattern: $0) })
                find.bind(5, result.item.statusChanged)
                guard try find.step() else { continue }
                let rowid = find.int64(0)
                let firstSnapshot = find.int64(1)
                find.reset()
                if firstSnapshot == latest || closeAt == nil {
                    update.reset()
                    update.bind(1, result.sha256)
                    update.bind(2, rowid)
                    try update.step()
                } else {
                    copy.reset()
                    copy.bind(1, latest)
                    copy.bind(2, result.sha256)
                    copy.bind(3, rowid)
                    try copy.step()
                    close.reset()
                    close.bind(1, closeAt)
                    close.bind(2, rowid)
                    try close.step()
                }
            }
        }
    }

    /// Runs a hasher and stores its hashes as they arrive, in small batches, so a cancel or
    /// a crash keeps everything hashed so far.
    @discardableResult
    public func recordHashing(_ hasher: FileHasher,
                              onEvent: (@Sendable (HashEvent) -> Void)? = nil) async throws -> HashSummary? {
        var batch: [HashResult] = []
        var summary: HashSummary?
        var lastWrite = Date()
        for await event in hasher.run() {
            onEvent?(event)
            switch event {
            case .hashed(let result):
                batch.append(result)
                if batch.count >= 100 || Date().timeIntervalSince(lastWrite) > 1 {
                    try record(batch)
                    batch.removeAll(keepingCapacity: true)
                    lastWrite = Date()
                }
            case .finished(let value):
                summary = value
            case .progress, .issue:
                break
            }
        }
        try record(batch)
        return summary
    }
}
