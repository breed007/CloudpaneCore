import Foundation

public enum IncrementalOutcome: Sendable, Equatable {
    /// A new complete snapshot holding the base plus the changes.
    case recorded(Int64)
    /// The changes cannot be applied piecemeal; run a full scan.
    case needsFullRescan(String)
}

extension Inventory {
    /// Records an incremental snapshot on top of the latest complete one: the changed paths
    /// are rescanned and merged, and everything else carries forward without being written.
    ///
    /// Per-root totals that come from rows (files, bytes, placeholders, packages) are
    /// recomputed. Counts only a full walk can see (folders, skipped links and other types,
    /// errors) carry over from the base snapshot until the next full scan.
    public func recordIncremental(_ scanner: IncrementalScanner, homePath: String) async throws -> IncrementalOutcome {
        await acquireWrite()
        defer { releaseWrite() }
        let latest = try db.prepare("SELECT MAX(id) FROM snapshots WHERE status = 'complete'")
        _ = try latest.step()
        guard let base = latest.int64OrNil(0) else {
            return .needsFullRescan("There is no complete scan to build on yet.")
        }
        let started = Date()
        let id = try beginSnapshot(homePath: homePath, placeholderRule: scanner.placeholderRule.id,
                                   startedAt: started, kind: "incremental", base: base)
        let result = await scanner.run(snapshotID: id)
        if let reason = result.fullRescanReason {
            try deleteSnapshot(id)
            return .needsFullRescan(reason)
        }
        do {
            try insert(result.records)
            try db.transaction {
                try merge(id, scope: result.scope)
                try recomputeRoots(id, base: base, elapsedMilliseconds: Date().timeIntervalSince(started) * 1000)
                let finish = try db.prepare("UPDATE snapshots SET status = 'complete', finished_at = ? WHERE id = ?")
                finish.bind(1, Date())
                finish.bind(2, id)
                try finish.step()
            }
        } catch {
            try? deleteSnapshot(id)
            throw error
        }
        return .recorded(id)
    }

    /// Removes a snapshot that never became one, with its staged rows.
    func deleteSnapshot(_ id: Int64) throws {
        try db.transaction {
            for sql in ["DELETE FROM files WHERE snapshot_id = ?1 AND staged = 1",
                        "DELETE FROM snapshot_roots WHERE snapshot_id = ?1",
                        "DELETE FROM snapshots WHERE id = ?1"] {
                let statement = try db.prepare(sql)
                statement.bind(1, id)
                try statement.step()
            }
        }
    }

    /// The base snapshot's roots, with totals recomputed from the merged current versions.
    private func recomputeRoots(_ id: Int64, base: Int64, elapsedMilliseconds: Double) throws {
        let statement = try db.prepare("""
            INSERT INTO snapshot_roots (snapshot_id, position, root_id, kind, provider, provider_name,
                name, account, path, top_level_depth, files, packages, directories,
                dataless_directories, logical_bytes, allocated_bytes, placeholders, placeholder_bytes,
                dataless, compressed, zero_byte, hard_links_skipped, symlinks_skipped,
                other_types_skipped, nested_roots_skipped, errors, package_logical_bytes,
                package_allocated_bytes, elapsed_ms, interrupted, backup_kind, offsite, unlisted_folders,
                unlisted_not_provided, unlisted_permission, unlisted_path_too_long)
            SELECT ?1, r.position, r.root_id, r.kind, r.provider, r.provider_name, r.name, r.account,
                r.path, r.top_level_depth, COALESCE(a.files, 0), COALESCE(a.packages, 0), r.directories,
                r.dataless_directories, COALESCE(a.logical, 0), COALESCE(a.allocated, 0),
                COALESCE(a.placeholders, 0), COALESCE(a.placeholder_bytes, 0), COALESCE(a.dataless, 0),
                COALESCE(a.compressed, 0), COALESCE(a.zero_byte, 0), r.hard_links_skipped,
                r.symlinks_skipped, r.other_types_skipped, r.nested_roots_skipped, r.errors,
                COALESCE(a.package_logical, 0), COALESCE(a.package_allocated, 0), ?3, 0,
                r.backup_kind, r.offsite, r.unlisted_folders, r.unlisted_not_provided,
                r.unlisted_permission, r.unlisted_path_too_long
            FROM snapshot_roots r LEFT JOIN (
                SELECT root_id, COUNT(*) AS files, SUM(is_package) AS packages,
                    SUM(COALESCE(logical_size, 0)) AS logical, SUM(COALESCE(allocated_size, 0)) AS allocated,
                    SUM(is_placeholder) AS placeholders,
                    SUM(CASE WHEN is_placeholder THEN COALESCE(logical_size, 0) ELSE 0 END) AS placeholder_bytes,
                    SUM(is_dataless) AS dataless, SUM(is_compressed) AS compressed,
                    SUM(CASE WHEN is_package = 0 AND logical_size = 0 THEN 1 ELSE 0 END) AS zero_byte,
                    SUM(CASE WHEN is_package THEN COALESCE(logical_size, 0) ELSE 0 END) AS package_logical,
                    SUM(CASE WHEN is_package THEN COALESCE(allocated_size, 0) ELSE 0 END) AS package_allocated
                FROM files WHERE staged = 0 AND last_snapshot IS NULL GROUP BY root_id
            ) a ON a.root_id = r.root_id
            WHERE r.snapshot_id = ?2
            """)
        statement.bind(1, id)
        statement.bind(2, base)
        statement.bind(3, elapsedMilliseconds)
        try statement.step()
    }
}
