import XCTest
@testable import CloudpaneCore

final class CatalogTests: XCTestCase {
    private let validTier: [String: Any] = [
        "provider": "dropbox", "tier": "Test 2 TB", "planBytes": 2_000_000_000_000, "price": "11.99",
        "currency": "USD", "cycle": "month", "frequency": 1, "region": "US", "bundle": NSNull(),
        "verified": true, "sourceURL": "https://example.com/pricing", "asOf": "2026-10-24", "notes": NSNull(),
    ]

    private func catalog(asOf: Any? = "2026-10-24", tier: [String: Any]) throws -> Data {
        var object: [String: Any] = ["tiers": [tier]]
        if let asOf { object["asOf"] = asOf }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func tier(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var copy = validTier
        change(&copy)
        return copy
    }

    func testBundledPriceCatalogLoadsAndIsComplete() throws {
        let catalog = try PriceCatalog.bundled()
        XCTAssertEqual(catalog.asOf, "2026-10-24")
        XCTAssertEqual(catalog.tiers.count, 23)
        XCTAssertEqual(Set(catalog.tiers.map(\.provider)), Set(ProviderRule.defaultTable.map(\.id)))
        XCTAssertTrue(catalog.tiers.allSatisfy { $0.planBytes > 0 }, "every tier has a plan size")
        XCTAssertTrue(catalog.tiers.allSatisfy { $0.sourceURL.hasPrefix("https://") }, "every tier has a source")
        XCTAssertTrue(catalog.tiers.allSatisfy { !$0.asOf.isEmpty })
        XCTAssertEqual(catalog.tiers.filter { $0.bundle == .appleOne }.count, 3)
        XCTAssertEqual(catalog.tiers.filter { $0.bundle == .microsoft365 }.count, 6)
        XCTAssertEqual(Set(catalog.tiers.filter { !$0.verified }.map(\.provider)), ["dropbox", "box"])

        let yearly = try XCTUnwrap(catalog.tiers(for: "dropbox").first { $0.cycle == .year })
        let filled = yearly.prefill()
        XCTAssertEqual(filled.monthly.amount, Decimal(string: "9.99"))
        XCTAssertEqual(filled.planBytes, 2_000_000_000_000)
        XCTAssertNil(filled.bundle)
        XCTAssertEqual(catalog.tiers(for: "icloud-drive").first { $0.tier == "Apple One Premier" }?.prefill().bundle,
                       .appleOne)
    }

    func testMissingCatalogAsOfFailsToLoad() throws {
        XCTAssertThrowsError(try PriceCatalog.load(catalog(asOf: nil, tier: validTier)))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(asOf: "someday", tier: validTier)))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["asOf"] = nil })))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["asOf"] = "" })))
        XCTAssertNoThrow(try PriceCatalog.load(catalog(tier: validTier)))
    }

    func testTierWithoutASourceFailsToLoad() throws {
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["sourceURL"] = nil })))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["sourceURL"] = "" })))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["sourceURL"] = "http://example.com" })))
    }

    func testTierWithoutAPositivePlanSizeFailsToLoad() throws {
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["planBytes"] = 0 })))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["planBytes"] = -5 })))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["price"] = "ten" })))
        XCTAssertThrowsError(try PriceCatalog.load(catalog(tier: tier { $0["currency"] = "usd" })))
    }

    func testProviderFactsAreDataAndHistoryNeedsASource() throws {
        let facts = try ProviderFacts.bundled()
        XCTAssertEqual(Set(facts.providers.map(\.provider)), Set(ProviderRule.defaultTable.map(\.id)))
        for fact in facts.providers {
            XCTAssertFalse(fact.sources.isEmpty, "\(fact.provider) cites no source")
            XCTAssertTrue(fact.sources.allSatisfy { $0.hasPrefix("https://") }, fact.provider)
            XCTAssertFalse(fact.retention?.isEmpty ?? true, fact.provider)
        }
        let iCloud = try XCTUnwrap(facts.fact(for: "icloud-drive"))
        XCTAssertEqual(iCloud.sources, ["https://support.apple.com/guide/icloud/recover-deleted-files-mmae56ea1ca5/icloud",
                                        "https://support.apple.com/en-us/111763"])
        XCTAssertTrue(iCloud.retention?.contains("recovery window for deleted files, not a history") == true)
        XCTAssertEqual(facts.fact(for: "icloud-drive")?.versioning, .noHistory)
        XCTAssertEqual(facts.fact(for: "box")?.requiresPaidPlan, true)
        XCTAssertEqual(Set(facts.providers.filter { $0.versioning == .keepsHistory }.map(\.provider)),
                       ["dropbox", "google-drive", "onedrive", "box"])

        let unsourced = #"{"asOf":"2026-10-24","providers":[{"provider":"box","versioning":"keepsHistory","retention":"10 versions.","sources":[]}]}"#
        XCTAssertThrowsError(try ProviderFacts.load(Data(unsourced.utf8)))
        let noHistoryUnsourced = #"{"asOf":"2026-10-24","providers":[{"provider":"icloud-drive","versioning":"noHistory","retention":"Deleted files for 30 days.","sources":[]}]}"#
        XCTAssertThrowsError(try ProviderFacts.load(Data(noHistoryUnsourced.utf8)), "no history is a claim too")
        let plainHTTP = #"{"asOf":"2026-10-24","providers":[{"provider":"box","versioning":"noHistory","retention":"None.","sources":["http://example.com"]}]}"#
        XCTAssertThrowsError(try ProviderFacts.load(Data(plainHTTP.utf8)))
        let noRetention = #"{"asOf":"2026-10-24","providers":[{"provider":"box","versioning":"keepsHistory","sources":["https://example.com"]}]}"#
        XCTAssertThrowsError(try ProviderFacts.load(Data(noRetention.utf8)), "a claim must say what is kept")
        let toVerify = #"{"asOf":"2026-10-24","providers":[{"provider":"box","versioning":"toVerify","sources":[]}]}"#
        XCTAssertNoThrow(try ProviderFacts.load(Data(toVerify.utf8)))
        let sourced = #"{"asOf":"2026-10-24","providers":[{"provider":"box","versioning":"keepsHistory","retention":"10 versions.","sources":["https://example.com"]}]}"#
        let loaded = try ProviderFacts.load(Data(sourced.utf8))
        XCTAssertEqual(loaded.fact(for: "box")?.retention, "10 versions.")
        XCTAssertThrowsError(try ProviderFacts.load(Data(#"{"providers":[]}"#.utf8)), "as-of date is required")
    }
}
