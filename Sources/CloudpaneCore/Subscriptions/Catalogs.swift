import Foundation

public enum CatalogError: Error, CustomStringConvertible, Sendable, Equatable {
    case missingResource(String)
    case invalid(String, [String])

    public var description: String {
        switch self {
        case .missingResource(let name): return "The bundled \(name) is missing"
        case .invalid(let name, let problems): return "The \(name) is invalid: " + problems.joined(separator: "; ")
        }
    }
}

/// A calendar date such as "2026-10-24", kept as written and checked on load.
private func isISODate(_ text: String) -> Bool {
    (try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day())) != nil
}

// MARK: - Price catalog

/// One consumer tier: what pre-fills the price field when the user picks it.
public struct PriceTier: Sendable, Hashable, Codable, Identifiable {
    public let provider: String
    public let tier: String
    public let planBytes: Int64
    /// A decimal string, so no binary floating point ever touches a price.
    let price: String
    public let currency: String
    public let cycle: BillingCycle
    public let frequency: Int
    public let region: String
    public let bundle: BundleKind?
    /// False when the source page did not show the figure; the app labels such a price as
    /// unconfirmed.
    public let verified: Bool
    public let sourceURL: String
    public let asOf: String
    public let notes: String?

    public var id: String { "\(provider)/\(tier)" }
    public var priceAmount: Decimal { Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }

    /// A new subscription filled in from this tier.
    public func prefill() -> Subscription {
        Subscription(provider: provider, name: tier, price: priceAmount, currency: currency, cycle: cycle,
                     frequency: frequency, url: sourceURL, planBytes: planBytes, bundle: bundle)
    }

    var problems: [String] {
        var found: [String] = []
        let label = "\(provider) \(tier)"
        if planBytes <= 0 { found.append("\(label): plan size must be more than zero") }
        if Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")) == nil || priceAmount < 0 {
            found.append("\(label): price \(price) is not a non-negative decimal")
        }
        if !Subscription.isCurrencyCode(currency) { found.append("\(label): currency \(currency) is not an ISO code") }
        if frequency < 1 { found.append("\(label): frequency must be at least 1") }
        if region.isEmpty { found.append("\(label): region is missing") }
        if !sourceURL.lowercased().hasPrefix("https://") || URL(string: sourceURL)?.host == nil {
            found.append("\(label): source URL is missing or not https")
        }
        if !isISODate(asOf) { found.append("\(label): as-of date \(asOf) is not a date") }
        return found
    }
}

/// Bundled consumer prices per provider and tier. Data, updated with releases.
public struct PriceCatalog: Sendable, Hashable, Codable {
    /// The date the prices were collected.
    public let asOf: String
    public let tiers: [PriceTier]

    /// The catalog shipped in this build.
    public static func bundled() throws -> PriceCatalog {
        guard let url = Bundle.module.url(forResource: "price-catalog", withExtension: "json") else {
            throw CatalogError.missingResource("price catalog")
        }
        return try load(Data(contentsOf: url))
    }

    /// Decodes and validates. Every field is required, including both as-of dates; a tier
    /// with no source, a plan size of zero or less, or a malformed price fails the load.
    public static func load(_ data: Data) throws -> PriceCatalog {
        let catalog = try JSONDecoder().decode(PriceCatalog.self, from: data)
        var problems = catalog.tiers.flatMap(\.problems)
        if !isISODate(catalog.asOf) { problems.insert("catalog as-of date \(catalog.asOf) is not a date", at: 0) }
        guard problems.isEmpty else { throw CatalogError.invalid("price catalog", problems) }
        return catalog
    }

    public func tiers(for provider: String) -> [PriceTier] {
        tiers.filter { $0.provider == provider }
    }
}

// MARK: - Provider facts

/// What is known about a provider's file version history.
public enum VersioningFact: String, Sendable, Hashable, Codable {
    /// Confirmed from a cited source.
    case keepsHistory
    /// Confirmed that the provider keeps no history.
    case noHistory
    /// Not yet confirmed. The grade treats this as unknown, never as a pass.
    case toVerify
}

public struct ProviderFact: Sendable, Hashable, Codable {
    public let provider: String
    public let versioning: VersioningFact
    /// What the provider keeps, as a sentence the grade quotes, such as "Old versions are
    /// kept for 30 days on Basic, Plus and Family plans."
    public let retention: String?
    /// History only when the user has an active paid plan with this provider (Box).
    public let requiresPaidPlan: Bool?
    /// The provider's own pages the fact rests on. Required for any claim, either way.
    public let sources: [String]
    public let notes: String?

    public init(provider: String, versioning: VersioningFact, retention: String? = nil,
                requiresPaidPlan: Bool? = nil, sources: [String] = [], notes: String? = nil) {
        self.provider = provider
        self.versioning = versioning
        self.retention = retention
        self.requiresPaidPlan = requiresPaidPlan
        self.sources = sources
        self.notes = notes
    }
}

/// Per-provider facts the grade needs, as data. A claim of history must cite a source.
public struct ProviderFacts: Sendable, Hashable, Codable {
    public let asOf: String
    public let providers: [ProviderFact]

    public init(asOf: String, providers: [ProviderFact]) {
        self.asOf = asOf
        self.providers = providers
    }

    public static func bundled() throws -> ProviderFacts {
        guard let url = Bundle.module.url(forResource: "provider-facts", withExtension: "json") else {
            throw CatalogError.missingResource("provider facts")
        }
        return try load(Data(contentsOf: url))
    }

    public static func load(_ data: Data) throws -> ProviderFacts {
        let facts = try JSONDecoder().decode(ProviderFacts.self, from: data)
        var problems: [String] = []
        if !isISODate(facts.asOf) { problems.append("as-of date \(facts.asOf) is not a date") }
        // A claim either way, history or none, must cite the provider's own pages and say
        // what is kept. Only "to verify" may stand without a source.
        for fact in facts.providers where fact.versioning != .toVerify {
            let cited = !fact.sources.isEmpty && fact.sources.allSatisfy {
                $0.lowercased().hasPrefix("https://") && URL(string: $0)?.host != nil
            }
            if !cited { problems.append("\(fact.provider): a \(fact.versioning.rawValue) claim needs https sources") }
            if (fact.retention ?? "").isEmpty {
                problems.append("\(fact.provider): a \(fact.versioning.rawValue) claim must say what is kept")
            }
        }
        guard problems.isEmpty else { throw CatalogError.invalid("provider facts", problems) }
        return facts
    }

    public func fact(for provider: String) -> ProviderFact? {
        providers.first { $0.provider == provider }
    }
}
