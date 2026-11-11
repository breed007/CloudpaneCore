import Foundation

/// A folder the user added as a backup destination, with the read-only security-scoped
/// bookmark the app resolves to reach it.
public struct BackupLocation: Sendable, Hashable, Identifiable {
    public var id: Int64?
    public var path: String
    public var label: String
    public var kind: BackupKind
    public var isOffsite: Bool
    public var bookmark: Data
    public var addedAt: Date

    public init(id: Int64? = nil, path: String, label: String, kind: BackupKind, isOffsite: Bool,
                bookmark: Data, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.label = label
        self.kind = kind
        self.isOffsite = isOffsite
        self.bookmark = bookmark
        self.addedAt = addedAt
    }

    /// The scan root for this location, carrying its kind and off-site label.
    public var scanRoot: ScanRoot {
        .backup(URL(fileURLWithPath: path, isDirectory: true), label: label, kind: kind, offsite: isOffsite)
    }
}

public enum PlanError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalid([String])
    case providerTaken(String)

    public var description: String {
        switch self {
        case .invalid(let problems): return problems.joined(separator: " ")
        case .providerTaken(let provider): return "There is already a plan for \(provider). Edit that one instead."
        }
    }
}

extension Inventory {
    // MARK: - Subscriptions

    public func subscriptions() throws -> [Subscription] {
        let statement = try db.prepare("""
            SELECT id, provider, name, price, currency, cycle, frequency, next_payment,
                payment_method, category, url, notes, auto_renew, inactive, plan_bytes, bundle
            FROM subscriptions ORDER BY provider
            """)
        var result: [Subscription] = []
        while try statement.step() {
            let s = statement
            result.append(Subscription(
                id: s.int64(0), provider: s.string(1) ?? "", name: s.string(2) ?? "",
                price: Decimal(string: s.string(3) ?? "0", locale: Locale(identifier: "en_US_POSIX")) ?? 0,
                currency: s.string(4) ?? "", cycle: BillingCycle(rawValue: s.string(5) ?? "") ?? .month,
                frequency: s.int(6), nextPayment: s.dateOrNil(7), paymentMethod: s.string(8) ?? "",
                category: s.string(9) ?? "", url: s.string(10) ?? "", notes: s.string(11) ?? "",
                autoRenew: s.bool(12), inactive: s.bool(13), planBytes: s.int64OrNil(14),
                bundle: s.string(15).flatMap(BundleKind.init(rawValue:))))
        }
        return result
    }

    /// Inserts a new plan or updates an existing one (by id) and returns it with its id.
    /// One plan per provider: a second plan for the same provider is refused.
    @discardableResult
    public func save(_ subscription: Subscription) throws -> Subscription {
        let problems = subscription.validationProblems()
        guard problems.isEmpty else { throw PlanError.invalid(problems) }
        let taken = try db.prepare("SELECT id FROM subscriptions WHERE provider = ? AND id IS NOT ?")
        taken.bind(1, subscription.provider)
        taken.bind(2, subscription.id)
        if try taken.step() { throw PlanError.providerTaken(subscription.provider) }

        let sql = subscription.id == nil
            ? """
              INSERT INTO subscriptions (provider, name, price, currency, cycle, frequency,
                  next_payment, payment_method, category, url, notes, auto_renew, inactive,
                  plan_bytes, bundle, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              """
            : """
              UPDATE subscriptions SET provider = ?, name = ?, price = ?, currency = ?, cycle = ?,
                  frequency = ?, next_payment = ?, payment_method = ?, category = ?, url = ?,
                  notes = ?, auto_renew = ?, inactive = ?, plan_bytes = ?, bundle = ?,
                  updated_at = ?
              WHERE id = ?
              """
        let statement = try db.prepare(sql)
        let s = subscription
        statement.bind(1, s.provider)
        statement.bind(2, s.name)
        statement.bind(3, NSDecimalNumber(decimal: s.price).description(withLocale: Locale(identifier: "en_US_POSIX")))
        statement.bind(4, s.currency)
        statement.bind(5, s.cycle.rawValue)
        statement.bind(6, s.frequency)
        statement.bind(7, s.nextPayment)
        statement.bind(8, s.paymentMethod)
        statement.bind(9, s.category)
        statement.bind(10, s.url)
        statement.bind(11, s.notes)
        statement.bind(12, s.autoRenew)
        statement.bind(13, s.inactive)
        statement.bind(14, s.planBytes)
        statement.bind(15, s.bundle?.rawValue)
        statement.bind(16, Date())
        if let id = s.id { statement.bind(17, id) }
        try statement.step()
        var saved = subscription
        if saved.id == nil { saved.id = db.lastInsertRowID }
        return saved
    }

    public func deleteSubscription(id: Int64) throws {
        let statement = try db.prepare("DELETE FROM subscriptions WHERE id = ?")
        statement.bind(1, id)
        try statement.step()
    }

    // MARK: - Backup locations

    public func backupLocations() throws -> [BackupLocation] {
        let statement = try db.prepare("""
            SELECT id, path, label, kind, offsite, bookmark, added_at FROM backup_locations ORDER BY added_at, id
            """)
        var result: [BackupLocation] = []
        while try statement.step() {
            let s = statement
            result.append(BackupLocation(id: s.int64(0), path: s.string(1) ?? "", label: s.string(2) ?? "",
                                         kind: BackupKind(rawValue: s.string(3) ?? "") ?? .other,
                                         isOffsite: s.bool(4), bookmark: s.data(5) ?? Data(),
                                         addedAt: s.dateOrNil(6) ?? Date()))
        }
        return result
    }

    /// Adds a location or updates one (by id): label, kind, off-site and bookmark.
    @discardableResult
    public func save(_ location: BackupLocation) throws -> BackupLocation {
        let statement: SQLiteStatement
        if let id = location.id {
            statement = try db.prepare("""
                UPDATE backup_locations SET path = ?, label = ?, kind = ?, offsite = ?, bookmark = ?,
                    added_at = ? WHERE id = ?
                """)
            statement.bind(7, id)
        } else {
            statement = try db.prepare("""
                INSERT INTO backup_locations (path, label, kind, offsite, bookmark, added_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
        }
        statement.bind(1, location.path)
        statement.bind(2, location.label)
        statement.bind(3, location.kind.rawValue)
        statement.bind(4, location.isOffsite)
        statement.bind(5, location.bookmark)
        statement.bind(6, location.addedAt)
        try statement.step()
        var saved = location
        if saved.id == nil { saved.id = db.lastInsertRowID }
        return saved
    }

    /// Removes the location and its bookmark. Past scans keep the root rows they recorded.
    public func removeBackupLocation(id: Int64) throws {
        let statement = try db.prepare("DELETE FROM backup_locations WHERE id = ?")
        statement.bind(1, id)
        try statement.step()
    }

    // MARK: - Usage history

    /// The complete scans the plan table needs, oldest first: the latest, and the scan to
    /// measure growth and dead weight against. That is the newest complete scan at least
    /// PlanReport.minimumGrowthWindow older than the latest, chosen by time, so any number of
    /// scans in a day never hides it. When there is no such scan, the previous complete scan
    /// is returned instead, so the plan table can say why growth is hidden.
    public func usageHistory() throws -> [UsagePoint] {
        let latest = try db.prepare("""
            SELECT id, finished_at FROM snapshots WHERE status = 'complete' ORDER BY id DESC LIMIT 1
            """)
        guard try latest.step() else { return [] }
        let latestID = latest.int64(0)
        let latestFinished = latest.dateOrNil(1) ?? .distantPast

        let baseline = try db.prepare("""
            SELECT id, finished_at FROM snapshots
            WHERE status = 'complete' AND id != ?1 AND finished_at <= ?2
            ORDER BY finished_at DESC, id DESC LIMIT 1
            """)
        baseline.bind(1, latestID)
        baseline.bind(2, latestFinished.addingTimeInterval(-PlanReport.minimumGrowthWindow))
        var earlier: (Int64, Date)?
        if try baseline.step() {
            earlier = (baseline.int64(0), baseline.dateOrNil(1) ?? .distantPast)
        } else {
            let previous = try db.prepare("""
                SELECT id, finished_at FROM snapshots WHERE status = 'complete' AND id != ?1
                ORDER BY id DESC LIMIT 1
                """)
            previous.bind(1, latestID)
            if try previous.step() { earlier = (previous.int64(0), previous.dateOrNil(1) ?? .distantPast) }
        }

        var points: [UsagePoint] = []
        for (id, finished) in [earlier, (latestID, latestFinished)].compactMap({ $0 }) {
            points.append(UsagePoint(snapshotID: id, finishedAt: finished, usedBytes: try providerUsage(snapshotID: id)))
        }
        return points
    }

    /// Logical bytes per provider in one scan, from per-root totals. A complete scan that
    /// found no provider roots gives an empty map.
    private func providerUsage(snapshotID: Int64) throws -> [String: Int64] {
        let statement = try db.prepare("""
            SELECT provider, SUM(logical_bytes) FROM snapshot_roots
            WHERE snapshot_id = ? AND kind = 'provider' GROUP BY provider
            """)
        statement.bind(1, snapshotID)
        var used: [String: Int64] = [:]
        while try statement.step() { used[statement.string(0) ?? ""] = statement.int64(1) }
        return used
    }

    // MARK: - History

    /// Per-provider logical bytes in every complete snapshot, oldest first, from per-root
    /// totals, for the history chart. Backup roots are left out; unrecognized folders count
    /// under "unrecognized".
    public func totalsHistory() throws -> [HistoryPoint] {
        let statement = try db.prepare("""
            SELECT s.id, s.finished_at, r.provider, MAX(r.provider_name), SUM(r.logical_bytes), s.kind
            FROM snapshots s JOIN snapshot_roots r ON r.snapshot_id = s.id
            WHERE s.status = 'complete' AND r.kind != 'backup'
            GROUP BY s.id, r.provider
            ORDER BY s.id, r.provider
            """)
        var result: [HistoryPoint] = []
        while try statement.step() {
            result.append(HistoryPoint(snapshotID: statement.int64(0), date: statement.dateOrNil(1) ?? .distantPast,
                                       provider: statement.string(2) ?? "", providerName: statement.string(3) ?? "",
                                       logicalBytes: statement.int64(4), isIncremental: statement.string(5) == "incremental"))
        }
        return result
    }
}

public struct HistoryPoint: Sendable, Hashable, Identifiable {
    public let snapshotID: Int64
    public let date: Date
    public let provider: String
    public let providerName: String
    public let logicalBytes: Int64
    public let isIncremental: Bool
    public var id: String { "\(snapshotID)/\(provider)" }
}
