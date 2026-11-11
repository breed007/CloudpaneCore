import XCTest
@testable import CloudpaneCore

final class BillingTests: XCTestCase {
    private func plan(_ price: String, _ cycle: BillingCycle, every frequency: Int = 1,
                      currency: String = "USD", provider: String = "dropbox") -> Subscription {
        Subscription(provider: provider, name: "Plan", price: Decimal(string: price)!, currency: currency,
                     cycle: cycle, frequency: frequency)
    }

    private func assertMonthly(_ subscription: Subscription, _ expected: String, accuracy: Double = 1e-12,
                               line: UInt = #line) {
        let value = NSDecimalNumber(decimal: subscription.monthly.amount).doubleValue
        XCTAssertEqual(value, Double(expected)!, accuracy: accuracy, line: line)
    }

    func testEveryCycleAndFrequencyNormalizesToMonthly() {
        // A year is 365.25 days: 1 a day = 7 a week = 30.4375 a month.
        assertMonthly(plan("1", .day), "30.4375")
        assertMonthly(plan("7", .week), "30.4375")
        assertMonthly(plan("12", .month), "12")
        assertMonthly(plan("120", .year), "10")
        assertMonthly(plan("2", .day, every: 2), "30.4375")
        assertMonthly(plan("14", .week, every: 2), "30.4375")
        assertMonthly(plan("30", .month, every: 3), "10")
        assertMonthly(plan("240", .year, every: 2), "10")
        assertMonthly(plan("119.88", .year), "9.99")
        XCTAssertEqual(plan("119.88", .year).monthly.amount, Decimal(string: "9.99"), "exact in Decimal")
        XCTAssertEqual(plan("7", .week).monthly.amount, Decimal(string: "30.4375"), "exact, not just close")
        XCTAssertEqual(plan("1", .day).monthly.amount, Decimal(string: "30.4375"))
        XCTAssertEqual(plan("14", .week, every: 2).monthly.amount, Decimal(string: "30.4375"))
        XCTAssertEqual(plan("9.99", .month, currency: "eur").monthly.currency, "EUR")
        XCTAssertEqual(plan("0", .month).monthly.amount, 0)
    }

    func testTotalsArePerCurrencyAndLeaveOutBundlesAndInactivePlans() {
        var bundled = plan("19.95", .month, provider: "icloud-drive")
        bundled.bundle = .appleOne
        var inactive = plan("5", .month, provider: "box")
        inactive.inactive = true
        let plans = [plan("11.99", .month), plan("120", .year, currency: "EUR", provider: "onedrive"),
                     plan("1.99", .month, provider: "google-drive"), bundled, inactive]
        let personal = CurrencyTotals.personal(plans)
        XCTAssertEqual(personal.totals, [Money(amount: 10, currency: "EUR"),
                                         Money(amount: Decimal(string: "13.98")!, currency: "USD")])
        XCTAssertTrue(personal.isMixed)
        XCTAssertEqual(CurrencyTotals.bundled(plans).totals, [Money(amount: Decimal(string: "19.95")!, currency: "USD")])
        XCTAssertFalse(CurrencyTotals.personal([plan("1", .month)]).isMixed)
        XCTAssertTrue(CurrencyTotals.personal([]).isEmpty)
    }

    func testValidation() {
        XCTAssertTrue(plan("1", .month).validationProblems().isEmpty)
        var bad = plan("-1", .month, currency: "dollars")
        bad.frequency = 0
        bad.name = " "
        bad.planBytes = 0
        XCTAssertEqual(bad.validationProblems().count, 5)
        var huge = plan("1", .month)
        huge.planBytes = Subscription.maximumPlanBytes + 1
        XCTAssertEqual(huge.validationProblems(), ["Enter a plan size of 10,000 TB or less."])
    }
}

final class PlanReportTests: XCTestCase {
    private let tb: Int64 = 1_000_000_000_000
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func plan(_ provider: String, price: String = "10", currency: String = "USD", planTB: Int64? = 2,
                      bundle: BundleKind? = nil) -> Subscription {
        Subscription(provider: provider, name: provider, price: Decimal(string: price)!, currency: currency,
                     planBytes: planTB.map { $0 * tb }, bundle: bundle)
    }

    private func point(_ id: Int64, daysAfterStart: Double, _ used: [String: Int64]) -> UsagePoint {
        UsagePoint(snapshotID: id, finishedAt: start.addingTimeInterval(daysAfterStart * day), usedBytes: used)
    }

    func testHeadroomCostPerTBAndUsed() throws {
        let report = PlanReport.build(subscriptions: [plan("dropbox", price: "11.99")],
                                      usage: [point(1, daysAfterStart: 0, ["dropbox": tb / 2])])
        let row = try XCTUnwrap(report.rows.first)
        XCTAssertEqual(row.usedBytes, tb / 2)
        XCTAssertEqual(row.headroomBytes, 2 * tb - tb / 2)
        XCTAssertEqual(row.fractionUsed ?? 0, 0.25, accuracy: 1e-12)
        XCTAssertEqual(row.costPerTB, Money(amount: Decimal(string: "5.995")!, currency: "USD"))
        XCTAssertNil(plan("x", planTB: nil).planBytes)
        let noPlan = PlanReport.build(subscriptions: [plan("dropbox", planTB: nil)],
                                      usage: [point(1, daysAfterStart: 0, ["dropbox": 1])]).rows[0]
        XCTAssertNil(noPlan.headroomBytes)
        XCTAssertNil(noPlan.costPerTB)
        let absent = PlanReport.build(subscriptions: [plan("box")],
                                      usage: [point(1, daysAfterStart: 0, ["dropbox": 1])]).rows[0]
        XCTAssertNil(absent.usedBytes, "not on this Mac is not zero")
    }

    func testGrowthAndMonthsToFullNeedTwoCompleteScansADayApart() throws {
        let one = PlanReport.build(subscriptions: [plan("dropbox")], usage: [point(1, daysAfterStart: 0, ["dropbox": tb])])
        XCTAssertNil(one.rows[0].monthsToFull)
        XCTAssertNil(one.rows[0].growthPerMonth)
        XCTAssertEqual(one.rows[0].growthNote, "Growth appears after two complete scans.")
        XCTAssertNil(PlanReport.build(subscriptions: [plan("dropbox")], usage: []).rows[0].monthsToFull)

        let minutes = PlanReport.build(subscriptions: [plan("dropbox")], usage: [
            point(1, daysAfterStart: 0, ["dropbox": tb]), point(2, daysAfterStart: 0.01, ["dropbox": tb + 1_000_000_000])])
        XCTAssertNil(minutes.rows[0].monthsToFull)
        XCTAssertEqual(minutes.rows[0].growthNote, "Growth appears after two complete scans at least a day apart.")

        // 1 TB used, plan 2 TB, growing 0.1 TB in 365.25/12 days = 0.1 TB a month: 10 months.
        let month = 365.25 / 12
        let report = PlanReport.build(subscriptions: [plan("dropbox")], usage: [
            point(1, daysAfterStart: 0, ["dropbox": tb]),
            point(2, daysAfterStart: month, ["dropbox": tb + tb / 10])])
        let row = try XCTUnwrap(report.rows.first)
        XCTAssertEqual(row.growthPerMonth, tb / 10)
        XCTAssertEqual(row.monthsToFull ?? 0, 9, accuracy: 1e-9, "0.9 TB left at 0.1 TB a month")
        XCTAssertNil(row.growthNote)
        XCTAssertEqual(report.growthWindow?.to, start.addingTimeInterval(month * day))

        // Baseline skips a scan too close to the latest one.
        let skipped = PlanReport.build(subscriptions: [plan("dropbox")], usage: [
            point(1, daysAfterStart: 0, ["dropbox": tb]),
            point(2, daysAfterStart: month - 0.1, ["dropbox": 2 * tb]),
            point(3, daysAfterStart: month, ["dropbox": tb + tb / 10])])
        XCTAssertEqual(skipped.rows[0].growthPerMonth, tb / 10)

        let shrinking = PlanReport.build(subscriptions: [plan("dropbox")], usage: [
            point(1, daysAfterStart: 0, ["dropbox": tb]), point(2, daysAfterStart: 2, ["dropbox": tb - 5])])
        XCTAssertNil(shrinking.rows[0].monthsToFull)
        XCTAssertEqual(shrinking.rows[0].growthNote, "Not growing, so it is not on course to fill.")

        let over = PlanReport.build(subscriptions: [plan("dropbox", planTB: 1)], usage: [
            point(1, daysAfterStart: 0, ["dropbox": tb]), point(2, daysAfterStart: 2, ["dropbox": 2 * tb])])
        XCTAssertEqual(over.rows[0].monthsToFull, 0, "already over the plan")
        XCTAssertEqual(over.rows[0].headroomBytes, -tb)
    }

    func testDeadWeightNeedsUnderFivePercentInEachOfTheLastTwoScans() {
        let sparse: [String: Int64] = ["dropbox": tb / 100]  // 0.5% of 2 TB
        func deadWeight(_ subscription: Subscription, _ usage: [UsagePoint]) -> Bool {
            PlanReport.build(subscriptions: [subscription], usage: usage).rows[0].isDeadWeight
        }
        XCTAssertFalse(deadWeight(plan("dropbox"), [point(1, daysAfterStart: 0, sparse)]), "one scan is not enough")
        XCTAssertTrue(deadWeight(plan("dropbox"), [point(1, daysAfterStart: 0, sparse), point(2, daysAfterStart: 1, sparse)]))
        XCTAssertFalse(deadWeight(plan("dropbox"), [point(1, daysAfterStart: 0, ["dropbox": tb]),
                                                    point(2, daysAfterStart: 1, sparse)]), "busy in the earlier scan")
        XCTAssertFalse(deadWeight(plan("dropbox", bundle: .employerPaid),
                                  [point(1, daysAfterStart: 0, sparse), point(2, daysAfterStart: 1, sparse)]))
        XCTAssertFalse(deadWeight(plan("dropbox", price: "0"),
                                  [point(1, daysAfterStart: 0, sparse), point(2, daysAfterStart: 1, sparse)]))
        XCTAssertFalse(deadWeight(plan("box"), [point(1, daysAfterStart: 0, sparse), point(2, daysAfterStart: 1, sparse)]),
                       "a provider not on this Mac has no measured use")
    }

    func testConsolidationOptionsNeverDoubleBookHeadroom() {
        // Dropbox has 1.5 TB free. Box and OneDrive each hold 1 TB: both cannot move in.
        let usage = [point(1, daysAfterStart: 0, ["dropbox": tb / 2, "box": tb, "onedrive": tb])]
        let report = PlanReport.build(subscriptions: [
            plan("dropbox", price: "11.99"), plan("box", price: "14"), plan("onedrive", price: "9.99"),
        ], usage: usage)
        var room = ["dropbox": 2 * tb - tb / 2, "box": tb, "onedrive": tb]
        for option in report.options {
            room[option.into, default: 0] -= option.movedBytes
            XCTAssertGreaterThanOrEqual(room[option.into] ?? 0, 0, "options overbook \(option.into)")
        }
        XCTAssertEqual(report.options.map(\.id), ["box->dropbox"])
    }

    func testConsolidationOptionsStayWithinACurrencyAndNeverIncludeBundles() {
        let usage = [point(1, daysAfterStart: 0, ["dropbox": tb / 2, "google-drive": tb / 10, "box": tb / 20,
                                                  "onedrive": tb / 10, "icloud-drive": tb / 10])]
        let report = PlanReport.build(subscriptions: [
            plan("dropbox", price: "11.99"), plan("google-drive", price: "9.99"),
            plan("box", price: "14", currency: "EUR", planTB: 1),
            plan("onedrive", price: "9.99", bundle: .microsoft365),
            plan("icloud-drive", price: "2.99", planTB: 1),
        ], usage: usage)
        // Dropbox moves into Google Drive; Google Drive now receives files, so it is not
        // also offered for canceling; iCloud Drive fits in what Google Drive has left.
        XCTAssertEqual(report.options.map(\.id), ["dropbox->google-drive", "icloud-drive->google-drive"])
        XCTAssertEqual(report.options.first?.monthlySaving, Money(amount: Decimal(string: "11.99")!, currency: "USD"))
        XCTAssertEqual(report.options.first?.headroomAfter, 2 * tb - tb / 10 - tb / 2)
        XCTAssertEqual(report.options.last?.headroomAfter, 2 * tb - tb / 10 - tb / 2 - tb / 10)
        XCTAssertFalse(report.options.contains { $0.cancel == "onedrive" || $0.into == "onedrive" })
        XCTAssertFalse(report.options.contains { $0.cancel == "box" || $0.into == "box" }, "no cross-currency moves")
    }
}
