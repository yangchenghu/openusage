import Foundation

/// The spend period the Total Spend card can show — matching the three per-provider spend tiles
/// `SpendTileMapper` emits, whose line labels double as the lookup keys here.
enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30 = "Last 30 Days"

    var id: String { rawValue }

    /// The metric-line label this period sums across providers (identical to the raw value today,
    /// but kept as its own accessor so the two meanings can diverge without a hunt).
    var lineLabel: String { rawValue }

    /// Compact segment title for the period switcher — "Last 30 Days" doesn't fit three-across
    /// in the 320pt popover without shrinking every segment.
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30: "30 Days"
        }
    }
}

/// One provider's contribution to a period's total: dollars and tokens from the same spend line,
/// plus whether the dollars are a local estimate (log-scanned providers) or measured (Cursor usage events).
struct TotalSpendSlice: Identifiable, Equatable {
    let provider: Provider
    let amountUSD: Double
    let tokenCount: Double
    let estimated: Bool
    let hasCostData: Bool
    let hasTokenData: Bool

    var id: String { provider.id }
}

/// A period's cross-provider raw totals: every spend-capable provider that contributed dollars and/or
/// tokens, kept in dashboard provider order.
struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    let slices: [TotalSpendSlice]

    var totalUSD: Double { slices.reduce(0) { $0 + $1.amountUSD } }
    var totalTokens: Double { slices.reduce(0) { $0 + $1.tokenCount } }
    /// The combined number is an estimate as soon as any contributor's dollars are imputed locally.
    var isEstimated: Bool { slices.contains(where: \.estimated) }
    /// Raw storage empty — no provider had dollars or tokens for the period.
    var isEmpty: Bool { slices.isEmpty }
}

/// Sums per-provider daily spend into one cross-provider total — the data source for the dashboard's
/// usage summary. Pure and synchronous: it reads already-refreshed `ProviderSnapshot`s and
/// never fetches. A provider contributes when its snapshot carries a `.values` line with the period's
/// label *and* that line has dollars and/or tokens — idle periods (no line) are excluded, never zero.
enum TotalSpendAggregator {
    /// The total for one period across `providers`, preserving their display order.
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot]
    ) -> TotalSpend {
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
            guard let snapshot = snapshots[provider.id],
                  let line = snapshot.line(label: period.lineLabel),
                  case .values(_, let values, _, _, _, _) = line else { return nil }

            let dollars = values.filter { $0.kind == .dollars }
            let amount = dollars.reduce(0) { $0 + $1.number }
            let tokenValues = values.filter { $0.kind == .count && $0.label == "tokens" }
            let tokens = tokenValues.reduce(0) { $0 + $1.number }
            guard amount > 0 || tokens > 0 else { return nil }

            return TotalSpendSlice(
                provider: provider,
                amountUSD: max(amount, 0),
                tokenCount: max(tokens, 0),
                estimated: dollars.contains(where: \.estimated),
                hasCostData: !dollars.isEmpty,
                hasTokenData: !tokenValues.isEmpty
            )
        }
        return TotalSpend(period: period, slices: slices)
    }
}
