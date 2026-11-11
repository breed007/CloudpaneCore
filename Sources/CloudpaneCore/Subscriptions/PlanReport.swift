import Foundation

/// Bytes per provider in one complete snapshot, from its per-root totals. A provider with no
/// root in that scan is absent, which means "not on this Mac", not zero.
public struct UsagePoint: Sendable, Hashable {
    public let snapshotID: Int64
    public let finishedAt: Date
    public let usedBytes: [String: Int64]

    public init(snapshotID: Int64, finishedAt: Date, usedBytes: [String: Int64]) {
        self.snapshotID = snapshotID
        self.finishedAt = finishedAt
        self.usedBytes = usedBytes
    }
}

/// One line of the plan table.
public struct PlanRow: Sendable, Hashable, Identifiable {
    public let subscription: Subscription
    public var id: String { subscription.provider }
    public let monthly: Money
    /// A plan with no folder on this Mac: no space used, room left, growth or dead weight,
    /// and never the target of a consolidation option.
    public let isCostOnly: Bool
    /// Logical bytes in the latest complete scan, or the total the user entered when there
    /// is one (see reportedTotal); nil when neither exists.
    public let usedBytes: Int64?
    /// The account total the user entered, when usedBytes comes from it instead of the scan.
    public let reportedTotal: ReportedUsage?
    /// Plan size minus used. Negative means over the plan.
    public let headroomBytes: Int64?
    public let fractionUsed: Double?
    /// Monthly price per terabyte of plan size (10^12 bytes).
    public let costPerTB: Money?
    /// Growth per month between two complete scans; nil when hidden (see growthNote).
    public let growthPerMonth: Int64?
    /// Months until used reaches the plan size at that growth; nil when not growing or hidden.
    public let monthsToFull: Double?
    /// Why growth or months to full are not shown, as a sentence.
    public let growthNote: String?
    /// Under 5% of the plan used in each of the last two complete scans.
    public let isDeadWeight: Bool
}

/// "Move one provider's files into another and cancel it." Stated as an option, never as
/// advice: it never adds a cloud copy, and the app always shows it beside the backup grade,
/// because canceling a provider removes a copy.
public struct ConsolidationOption: Sendable, Hashable, Identifiable {
    /// The provider that would be canceled.
    public let cancel: String
    /// The provider whose plan has room for it.
    public let into: String
    public let movedBytes: Int64
    public let headroomAfter: Int64
    public let monthlySaving: Money
    public var id: String { "\(cancel)->\(into)" }
}

public struct PlanReport: Sendable, Hashable {
    public let rows: [PlanRow]
    public let personalTotal: CurrencyTotals
    public let bundledTotal: CurrencyTotals
    public let options: [ConsolidationOption]
    /// The two scans growth was measured between, when shown.
    public let growthWindow: (from: Date, to: Date)?

    /// Bytes per terabyte, as providers sell plans.
    public static let terabyte: Decimal = 1_000_000_000_000
    /// Dead weight: under this fraction of the plan in each of the last two complete scans.
    public static let deadWeightFraction = 0.05
    /// Growth is measured only between scans at least this far apart, so two scans minutes
    /// apart cannot project a plan full in an hour.
    public static let minimumGrowthWindow: TimeInterval = 24 * 60 * 60
    static let daysPerMonth = 365.25 / 12

    /// Builds the table. usage is complete scans, oldest first; Inventory.usageHistory()
    /// returns the latest and its baseline. reported holds totals the user entered, by
    /// provider; a total replaces the scanned figure for that provider's used, headroom and
    /// cost lines, because it covers what no scan can see (for iCloud: Photos, backups,
    /// Messages, Mail).
    /// costOnly holds provider ids of plans with no folder on this Mac (custom providers
    /// the user added for cost only): they count toward the totals and nothing else.
    public static func build(subscriptions: [Subscription], usage: [UsagePoint],
                             reported: [String: ReportedUsage] = [:],
                             costOnly: Set<String> = []) -> PlanReport {
        let latest = usage.last
        let baseline = latest.flatMap { last in
            usage.last { last.finishedAt.timeIntervalSince($0.finishedAt) >= minimumGrowthWindow }
        }
        let window: (from: Date, to: Date)? = {
            guard let latest, let baseline else { return nil }
            return (baseline.finishedAt, latest.finishedAt)
        }()

        let rows = subscriptions.sorted { $0.provider < $1.provider }.map { sub -> PlanRow in
            let monthly = sub.monthly
            let isCostOnly = costOnly.contains(sub.provider)
            let entered = isCostOnly ? nil : reported[sub.provider]
            let used = isCostOnly ? nil : entered?.bytes ?? latest?.usedBytes[sub.provider]
            let headroom = sub.planBytes.flatMap { plan in used.map { plan - $0 } }
            let fraction = sub.planBytes.flatMap { plan in used.map { Double($0) / Double(plan) } }
            let costPerTB = sub.planBytes.map {
                Money(amount: monthly.amount / (Decimal($0) / terabyte), currency: monthly.currency)
            }

            var growth: Int64?
            var months: Double?
            var note: String?
            if isCostOnly {
                note = "Not on this Mac, so only its cost is tracked."
            } else if entered != nil {
                // One typed-in figure has no earlier value to compare with, and comparing it
                // with a scanned figure would count Photos and backups as growth.
                note = "Growth is not measured while the plan uses the total you entered."
            } else if usage.count < 2 {
                note = "Growth appears after two complete scans."
            } else if baseline == nil {
                note = "Growth appears after two complete scans at least a day apart."
            } else if let latest, let baseline, let now = latest.usedBytes[sub.provider],
                      let then = baseline.usedBytes[sub.provider] {
                // The baseline is at least minimumGrowthWindow older, but never divide by zero.
                let days = max(latest.finishedAt.timeIntervalSince(baseline.finishedAt) / 86_400, 1)
                let perMonth = Int64((Double(now - then) / days * daysPerMonth).rounded())
                growth = perMonth
                if let headroom {
                    if headroom <= 0 {
                        months = 0
                    } else if perMonth > 0 {
                        months = Double(headroom) / Double(perMonth)
                    } else {
                        note = "Not growing, so it is not on course to fill."
                    }
                } else if sub.planBytes == nil {
                    note = "Enter the plan size to see months to full."
                }
            } else {
                note = "Growth needs this provider in both scans."
            }

            // Dead weight compares the same two scans as growth: the latest and the baseline
            // at least a day older.
            var deadWeight = false
            if !isCostOnly, let plan = sub.planBytes, sub.countsTowardPersonalTotal, sub.price > 0,
               let latest, let baseline,
               let now = latest.usedBytes[sub.provider], let before = baseline.usedBytes[sub.provider] {
                deadWeight = Double(now) / Double(plan) < deadWeightFraction
                    && Double(before) / Double(plan) < deadWeightFraction
                // An entered total covers more than the scan, so it can only clear the flag.
                if let entered, Double(entered.bytes) / Double(plan) >= deadWeightFraction {
                    deadWeight = false
                }
            }

            return PlanRow(subscription: sub, monthly: monthly, isCostOnly: isCostOnly, usedBytes: used,
                           reportedTotal: entered,
                           headroomBytes: headroom,
                           fractionUsed: fraction, costPerTB: costPerTB, growthPerMonth: growth,
                           monthsToFull: months, growthNote: note, isDeadWeight: deadWeight)
        }

        return PlanReport(rows: rows, personalTotal: .personal(subscriptions),
                          bundledTotal: .bundled(subscriptions), options: options(rows),
                          growthWindow: window)
    }

    /// Options that can all be taken together. Paid personal plans are considered from the
    /// largest saving down. Each moves into the plan, in the same currency, with the most
    /// room left after the options already chosen, so two options never count the same
    /// headroom twice. A plan that receives files is never also canceled, and a canceled
    /// plan never receives any.
    static func options(_ rows: [PlanRow]) -> [ConsolidationOption] {
        let eligible = rows.filter {
            !$0.isCostOnly && $0.subscription.countsTowardPersonalTotal && $0.subscription.price > 0
                && $0.usedBytes != nil && $0.headroomBytes != nil
        }
        var room = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0.headroomBytes ?? 0) })
        var canceled: Set<String> = []
        var receiving: Set<String> = []
        var found: [ConsolidationOption] = []
        for cancel in eligible.sorted(by: { ($0.monthly.amount, $1.id) > ($1.monthly.amount, $0.id) }) {
            guard !receiving.contains(cancel.id) else { continue }
            let moved = cancel.usedBytes ?? 0
            let targets = eligible.filter {
                $0.id != cancel.id && !canceled.contains($0.id)
                    && $0.monthly.currency == cancel.monthly.currency && (room[$0.id] ?? 0) >= moved
            }
            guard let into = targets.max(by: { (room[$0.id] ?? 0, $1.id) < (room[$1.id] ?? 0, $0.id) }) else { continue }
            room[into.id, default: 0] -= moved
            canceled.insert(cancel.id)
            receiving.insert(into.id)
            found.append(ConsolidationOption(cancel: cancel.id, into: into.id, movedBytes: moved,
                                             headroomAfter: room[into.id] ?? 0, monthlySaving: cancel.monthly))
        }
        return found
    }

    public static func == (lhs: PlanReport, rhs: PlanReport) -> Bool {
        lhs.rows == rhs.rows && lhs.options == rhs.options && lhs.personalTotal == rhs.personalTotal
            && lhs.bundledTotal == rhs.bundledTotal && lhs.growthWindow?.from == rhs.growthWindow?.from
            && lhs.growthWindow?.to == rhs.growthWindow?.to
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rows)
        hasher.combine(options)
    }
}
