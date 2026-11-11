import Foundation

/// How often a plan bills, combined with a frequency: every 3 months, every 2 years.
public enum BillingCycle: String, Sendable, Hashable, Codable, CaseIterable {
    case day
    case week
    case month
    case year

    /// Cycles per year as a fraction, so normalization divides once, at the end. A year is
    /// 365.25 days: 1 a day and 7 a week are both exactly 30.4375 a month.
    var perYear: (numerator: Decimal, denominator: Decimal) {
        switch self {
        case .day: return (Decimal(string: "365.25")!, 1)
        case .week: return (Decimal(string: "365.25")!, 7)
        case .month: return (12, 1)
        case .year: return (1, 1)
        }
    }
}

/// A plan that comes with something else. Shown, but never summed into the personal total.
public enum BundleKind: String, Sendable, Hashable, Codable, CaseIterable {
    case appleOne
    case googleOneFamily
    case microsoft365
    case employerPaid

    public var displayName: String {
        switch self {
        case .appleOne: return "Apple One"
        case .googleOneFamily: return "Google One family"
        case .microsoft365: return "Microsoft 365"
        case .employerPaid: return "Employer-paid"
        }
    }
}

/// An amount in one currency. Cloudpane never converts between currencies: there is no
/// network and no exchange-rate table.
public struct Money: Sendable, Hashable, Codable {
    public let amount: Decimal
    /// ISO 4217 code, uppercase.
    public let currency: String

    public init(amount: Decimal, currency: String) {
        self.amount = amount
        self.currency = currency.uppercased()
    }
}

/// One storage subscription, shaped after Wallos's entry form, plus plan size and a bundle
/// flag. At most one per provider.
public struct Subscription: Sendable, Hashable, Codable, Identifiable {
    /// Nil until saved.
    public var id: Int64?
    /// The provider rule id this plan belongs to, such as "dropbox".
    public var provider: String
    public var name: String
    public var price: Decimal
    public var currency: String
    public var cycle: BillingCycle
    /// Every N cycles. At least 1.
    public var frequency: Int
    public var nextPayment: Date?
    public var paymentMethod: String
    public var category: String
    public var url: String
    public var notes: String
    public var autoRenew: Bool
    public var inactive: Bool
    /// Plan size in bytes, as the provider sells it (decimal: 1 TB = 10^12 bytes).
    public var planBytes: Int64?
    public var bundle: BundleKind?

    public init(id: Int64? = nil, provider: String, name: String, price: Decimal, currency: String,
                cycle: BillingCycle = .month, frequency: Int = 1, nextPayment: Date? = nil,
                paymentMethod: String = "", category: String = "Cloud storage", url: String = "",
                notes: String = "", autoRenew: Bool = true, inactive: Bool = false,
                planBytes: Int64? = nil, bundle: BundleKind? = nil) {
        self.id = id
        self.provider = provider
        self.name = name
        self.price = price
        self.currency = currency.uppercased()
        self.cycle = cycle
        self.frequency = frequency
        self.nextPayment = nextPayment
        self.paymentMethod = paymentMethod
        self.category = category
        self.url = url
        self.notes = notes
        self.autoRenew = autoRenew
        self.inactive = inactive
        self.planBytes = planBytes
        self.bundle = bundle
    }

    /// The price per month: price x cycles per year / (12 x frequency), in Decimal with a
    /// single division. The result is exact whenever the true value has a terminating decimal
    /// form (7 a week is exactly 30.4375); otherwise it carries Decimal's 38 significant
    /// digits, and the app rounds only for display.
    public var monthly: Money {
        let frequency = Decimal(max(self.frequency, 1))
        let (numerator, denominator) = cycle.perYear
        return Money(amount: price * numerator / (denominator * 12 * frequency), currency: currency)
    }

    /// The largest plan size accepted: 10 PB, far above any consumer plan, and safely
    /// inside Int64 in any unit the form offers.
    public static let maximumPlanBytes: Int64 = 10_000_000_000_000_000

    /// Counted in the personal monthly total: active and not part of a bundle.
    public var countsTowardPersonalTotal: Bool { !inactive && bundle == nil }

    /// Problems that stop the plan from being saved, as sentences for the user.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if provider.isEmpty { problems.append("Choose a provider.") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Enter a name.") }
        if price < 0 { problems.append("The price cannot be negative.") }
        if !Subscription.isCurrencyCode(currency) {
            problems.append("Enter the currency as a three-letter code, such as USD or EUR.")
        }
        if frequency < 1 { problems.append("The billing frequency must be at least 1.") }
        if let planBytes, planBytes <= 0 { problems.append("The plan size must be more than zero.") }
        if let planBytes, planBytes > Subscription.maximumPlanBytes {
            problems.append("Enter a plan size of 10,000 TB or less.")
        }
        return problems
    }

    static func isCurrencyCode(_ code: String) -> Bool {
        code.count == 3 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    }
}

/// Monthly totals, one per currency, never converted into each other.
public struct CurrencyTotals: Sendable, Hashable {
    /// Sorted by currency code.
    public let totals: [Money]

    public var isMixed: Bool { totals.count > 1 }
    public var isEmpty: Bool { totals.isEmpty }

    init(_ amounts: [Money]) {
        var byCurrency: [String: Decimal] = [:]
        for money in amounts { byCurrency[money.currency, default: 0] += money.amount }
        totals = byCurrency.keys.sorted().map { Money(amount: byCurrency[$0]!, currency: $0) }
    }

    /// The personal monthly total: active plans that are not part of a bundle.
    public static func personal(_ subscriptions: [Subscription]) -> CurrencyTotals {
        CurrencyTotals(subscriptions.filter(\.countsTowardPersonalTotal).map(\.monthly))
    }

    /// Active bundle plans, shown separately and never added to the personal total.
    public static func bundled(_ subscriptions: [Subscription]) -> CurrencyTotals {
        CurrencyTotals(subscriptions.filter { !$0.inactive && $0.bundle != nil }.map(\.monthly))
    }
}
