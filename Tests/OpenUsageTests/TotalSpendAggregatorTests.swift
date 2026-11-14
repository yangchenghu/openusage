import XCTest
@testable import OpenUsage

/// Summary aggregation preserves provider order, tracks missing values, and marks local estimates.
final class TotalSpendAggregatorTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private func snapshot(_ provider: Provider, lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: lines,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func spendLine(
        _ label: String,
        dollars: Double? = nil,
        tokens: Double? = 1_000_000,
        estimated: Bool = false
    ) -> MetricLine {
        var values: [MetricValue] = []
        if let dollars {
            values.append(MetricValue(number: dollars, kind: .dollars, estimated: estimated))
        }
        if let tokens {
            values.append(MetricValue(number: tokens, kind: .count, label: "tokens"))
        }
        return .values(label: label, values: values)
    }

    func testSummaryKeepsProviderOrderAndBothQuantities() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2, tokens: 9_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 20, tokens: 100_000)])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        XCTAssertEqual(total.slices.map(\.provider.id), ["claude", "cursor"])
        XCTAssertEqual(total.slices[0].amountUSD, 2)
        XCTAssertEqual(total.slices[0].tokenCount, 9_000_000)
        XCTAssertEqual(total.totalUSD, 22)
        XCTAssertEqual(total.totalTokens, 9_100_000)
    }

    func testSummaryDistinguishesMissingValuesFromKnownZero() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: nil, tokens: 1_000)]),
            "codex": snapshot(codex, lines: [spendLine("Today", dollars: 0, tokens: 2_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 2, tokens: nil)])
        ]
        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)
        XCTAssertFalse(total.slices[0].hasCostData)
        XCTAssertTrue(total.slices[0].hasTokenData)
        XCTAssertTrue(total.slices[1].hasCostData)
        XCTAssertEqual(total.slices[1].amountUSD, 0)
        XCTAssertFalse(total.slices[2].hasTokenData)
    }

    func testDefaultTrendsAreEnabledOnDemandAndNeverPinned() {
        let trends = DefaultLayout.metricIDs.filter { $0.hasSuffix(".trend") }
        XCTAssertFalse(trends.isEmpty)
        XCTAssertTrue(Set(trends).isSubset(of: Set(DefaultLayout.expandedMetricIDs)))
        XCTAssertTrue(Set(trends).isDisjoint(with: DefaultLayout.pinnedMetricIDs))
    }

    func testSumsDollarsAndTokensAcrossProviders() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50, tokens: 100_000, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25, tokens: 500_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)

        XCTAssertEqual(Set(total.slices.map(\.provider.id)), Set(["cursor", "claude"]))
        XCTAssertEqual(total.totalUSD, 9.75, accuracy: 0.0001)
        XCTAssertEqual(total.totalTokens, 600_000, accuracy: 0.0001)
    }

    func testProviderWithoutPeriodLineIsExcludedNotZero() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 1.00)]),
            // Codex has spend for yesterday only — it must not appear in today's slices.
            "codex": snapshot(codex, lines: [spendLine("Yesterday", dollars: 3.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        XCTAssertEqual(total.slices.map(\.provider.id), ["claude"])
    }

    func testTokensOnlyLineContributesTokens() {
        let tokensOnly = spendLine("Today", dollars: nil, tokens: 500_000)
        let snapshots = ["claude": snapshot(claude, lines: [tokensOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertFalse(total.isEmpty)
        XCTAssertEqual(total.slices.first?.tokenCount, 500_000)
        XCTAssertEqual(total.slices.first?.amountUSD, 0)
    }

    func testDollarsOnlyLineContributesSpend() {
        let dollarsOnly = spendLine("Today", dollars: 4.00, tokens: nil)
        let snapshots = ["claude": snapshot(claude, lines: [dollarsOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertEqual(total.totalUSD, 4)
        XCTAssertEqual(total.totalTokens, 0)
    }

    func testTotalIsEstimatedWhenAnySliceIsEstimated() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.00, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 4.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        XCTAssertTrue(total.isEstimated)
    }

    func testEmptySummaryWhenNothingQualifies() {
        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: [:])
        XCTAssertTrue(total.isEmpty)
    }
}
