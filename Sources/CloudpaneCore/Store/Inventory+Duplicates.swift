import Foundation

extension Inventory {
    /// Duplicate groups in a complete snapshot, largest reclaimable first.
    ///
    /// Groups are formed from files in sync clouds (provider and unrecognized folders);
    /// matching copies in backup locations are attached to the listed groups for reference.
    /// Like the grade, on disk this runs on its own read-only connection off the actor, and
    /// canceling the caller interrupts the query in flight.
    public nonisolated func duplicates(snapshotID: Int64, limit: Int = 500) async throws -> DuplicateReport {
        if path == ":memory:" { return try await duplicatesOnActor(snapshotID: snapshotID, limit: limit) }
        // One streaming pass: a large page cache would only hold pages already read.
        let reader = ReaderHandle(try SQLiteConnection(path: path, readOnly: true))
        _ = try? reader.connection.execute("PRAGMA mmap_size = 268435456; PRAGMA cache_size = -8192")
        let work = Task.detached(priority: .utility) {
            try Inventory.duplicates(snapshotID: snapshotID, limit: limit, in: reader.connection)
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

    private func duplicatesOnActor(snapshotID: Int64, limit: Int) throws -> DuplicateReport {
        try Inventory.duplicates(snapshotID: snapshotID, limit: limit, in: db)
    }

    static let cloud = "f.provider != '\(ScanRoot.backupProvider)' AND f.logical_size > 0"

    /// The three candidate queries. Each reads only rows whose key occurs more than once,
    /// in key order, so the search streams one key at a time instead of loading the library.
    static func duplicateSQL(_ scope: String) -> [(tier: DuplicateTier, sql: String)] {
        let columns = "f.rowid, \(fileColumns(prefix: "f"))"
        return [
            (.exact, """
                SELECT \(columns), f.sha256 || '|' || f.logical_size FROM files f
                WHERE \(scope) AND \(cloud) AND f.is_package = 0 AND f.sha256 IS NOT NULL
                    AND (f.sha256, f.logical_size) IN (
                        SELECT f.sha256, f.logical_size FROM files f
                        WHERE \(scope) AND \(cloud) AND f.is_package = 0 AND f.sha256 IS NOT NULL
                        GROUP BY f.sha256, f.logical_size HAVING COUNT(*) > 1)
                ORDER BY f.sha256, f.logical_size
                """),
            (.strong, """
                SELECT \(columns), f.search_name || '|' || f.logical_size FROM files f
                WHERE \(scope) AND \(cloud)
                    AND (f.search_name, f.logical_size) IN (
                        SELECT f.search_name, f.logical_size FROM files f WHERE \(scope) AND \(cloud)
                        GROUP BY f.search_name, f.logical_size HAVING COUNT(*) > 1)
                ORDER BY f.search_name, f.logical_size
                """),
            (.weak, """
                SELECT \(columns), f.logical_size FROM files f
                WHERE \(scope) AND \(cloud) AND f.logical_size >= \(DuplicateFinder.weakMinimum)
                    AND f.logical_size IN (
                        SELECT f.logical_size FROM files f
                        WHERE \(scope) AND \(cloud) AND f.logical_size >= \(DuplicateFinder.weakMinimum)
                        GROUP BY f.logical_size HAVING COUNT(*) > 1)
                ORDER BY f.logical_size
                """),
        ]
    }

    static func duplicates(snapshotID: Int64, limit: Int, in db: SQLiteConnection) throws -> DuplicateReport {
        try requireComplete(snapshotID, allowIncomplete: false, in: db)
        let scope = try rows(of: snapshotID, in: db)
        let roots = Dictionary(uniqueKeysWithValues: try rootSummaries(snapshotID: snapshotID, in: db).map { ($0.root.id, $0.root) })
        func location(_ record: FileRecord) -> String {
            let root = roots[record.rootID]
            return record.provider == ScanRoot.backupProvider ? (root?.name ?? "Backup") : (root?.providerName ?? record.provider)
        }

        var collector = DuplicateFinder.Collector(limit: limit)
        var used = Set<Int64>()
        for (tier, sql) in duplicateSQL(scope) {
            let statement = try db.prepare(sql)
            var key: String?
            var members: [DuplicateFinder.Candidate] = []
            var rows = 0
            func flush() {
                defer { members.removeAll(keepingCapacity: true) }
                let fresh = members.filter { !used.contains($0.rowid) }
                guard fresh.count > 1, let key else { return }
                let groups: [[DuplicateFinder.Candidate]]
                switch tier {
                case .exact: groups = [fresh]
                case .strong: groups = DuplicateFinder.clusters(fresh).map(DuplicateFinder.withoutConflictingHashes)
                case .weak: groups = [DuplicateFinder.withoutConflictingHashes(fresh)]
                }
                for (index, group) in groups.enumerated() where group.count > 1 {
                    group.forEach { used.insert($0.rowid) }
                    collector.add(DuplicateFinder.group(tier, group, id: "\(tier.rawValue)-\(key)-\(index)"))
                }
            }
            while try statement.step() {
                rows += 1
                if rows % 10_000 == 0 { try Task.checkCancellation() }
                let rowKey = statement.string(fileColumnCount + 1) ?? ""
                if rowKey != key {
                    flush()
                    key = rowKey
                }
                let record = readFile(statement, at: 1, snapshot: snapshotID)
                members.append(DuplicateFinder.Candidate(rowid: statement.int64(0), record: record,
                                                         locationName: location(record)))
            }
            flush()
        }
        collector.trim()

        // Backup copies, looked up by index for the listed groups only.
        let byHash = try db.prepare("""
            SELECT \(fileColumns(prefix: "f")) FROM files f
            WHERE \(scope) AND f.provider = '\(ScanRoot.backupProvider)' AND f.is_placeholder = 0
                AND f.sha256 = ?1 AND f.logical_size = ?2 ORDER BY f.path
            """)
        let byName = try db.prepare("""
            SELECT \(fileColumns(prefix: "f")) FROM files f
            WHERE \(scope) AND f.provider = '\(ScanRoot.backupProvider)' AND f.is_placeholder = 0
                AND f.search_name = ?1 AND f.logical_size = ?2 AND f.modified_at BETWEEN ?3 AND ?4 ORDER BY f.path
            """)
        let groups = try collector.kept.map { group -> DuplicateGroup in
            let first = group.copies[0].record
            var backups: [DuplicateCopy] = []
            switch group.tier {
            case .exact:
                byHash.reset()
                byHash.bind(1, first.sha256)
                byHash.bind(2, group.size)
                while try byHash.step() {
                    let record = readFile(byHash, snapshot: snapshotID)
                    backups.append(DuplicateCopy(record: record, locationName: location(record), isBackup: true))
                }
            case .strong:
                let dates = group.copies.compactMap(\.record.modified)
                guard let earliest = dates.min(), let latest = dates.max() else { break }
                byName.reset()
                byName.bind(1, SearchKey.make(first.name))
                byName.bind(2, group.size)
                byName.bind(3, earliest.addingTimeInterval(-matchWindow))
                byName.bind(4, latest.addingTimeInterval(matchWindow))
                while try byName.step() {
                    let record = readFile(byName, snapshot: snapshotID)
                    backups.append(DuplicateCopy(record: record, locationName: location(record), isBackup: true))
                }
            case .weak:
                // Size alone says too little to call a backup file a copy.
                break
            }
            return DuplicateGroup(tier: group.tier, size: group.size, copies: group.copies, backupCopies: backups, id: group.id)
        }
        let totals = DuplicateTier.allCases.map { tier -> TierTotal in
            let value = collector.totals[tier] ?? (0, 0, 0)
            return TierTotal(tier: tier, groups: value.groups, files: value.files, reclaimableBytes: value.bytes)
        }
        return DuplicateReport(snapshotID: snapshotID, groups: groups, totals: totals)
    }

    /// EXPLAIN QUERY PLAN for each candidate query, for the test that guards index use.
    func duplicateQueryPlans(snapshotID: Int64) throws -> [DuplicateTier: [String]] {
        var plans: [DuplicateTier: [String]] = [:]
        for (tier, sql) in Inventory.duplicateSQL(try rows(of: snapshotID)) {
            let statement = try db.prepare("EXPLAIN QUERY PLAN " + sql)
            var lines: [String] = []
            while try statement.step() { lines.append(statement.string(3) ?? "") }
            plans[tier] = lines
        }
        return plans
    }
}
