import Foundation

/// US Dollar Index: the ICE DXY quote (`DX-Y.NYB`) from Yahoo Finance's public chart API. No account or
/// key is needed, so it is always "detected". It refreshes every minute — the index moves far slower
/// than crypto, and Yahoo rate limits aggressive polling.
@MainActor
final class DollarIndexProvider: ProviderRuntime {
    static let providerID = "dxy"
    static let symbol = "DX-Y.NYB"
    static let refreshSeconds: TimeInterval = 60

    static let priceDescriptorID = "dxy.price"
    static let rangeDescriptorID = "dxy.range"

    let provider = Provider(
        id: DollarIndexProvider.providerID,
        displayName: "US Dollar Index",
        icon: .providerMark(DollarIndexProvider.providerID)
    )

    private let client: YahooChartClient
    private let now: @Sendable () -> Date

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = YahooChartClient(http: http)
        self.now = now
    }

    var refreshInterval: TimeInterval { Self.refreshSeconds }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .values(id: Self.priceDescriptorID, provider: provider, title: DollarIndexMapper.priceLabel,
                    metricLabel: DollarIndexMapper.priceLabel),
            .values(id: Self.rangeDescriptorID, provider: provider, title: DollarIndexMapper.rangeLabel,
                    metricLabel: DollarIndexMapper.rangeLabel, valueSeparator: " – ")
        ]
    }

    /// Public market data needs no credentials, so new-provider detection always offers it.
    func hasLocalCredentials() async -> Bool { true }

    func refresh() async -> ProviderSnapshot {
        let quote: DollarIndexQuote
        do {
            quote = try await client.fetchQuote(symbol: Self.symbol)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        return ProviderSnapshot.make(
            provider: provider,
            plan: "Yahoo · ICE",
            lines: DollarIndexMapper.lines(quote: quote),
            refreshedAt: now()
        )
    }
}

/// Normalizes a DXY quote into a price row (last price + change vs. the previous close) and a day range
/// row (low then high, rendered as a span). Line labels are the stable keys the descriptors match on.
enum DollarIndexMapper {
    static let priceLabel = "DXY"
    static let rangeLabel = "DXY Day Range"

    static func lines(quote: DollarIndexQuote) -> [MetricLine] {
        var priceValues = [MetricValue(number: quote.price, kind: .price)]
        if let change = quote.changePercent {
            priceValues.append(MetricValue(number: change, kind: .change))
        }
        return [
            .values(label: priceLabel, values: priceValues),
            .values(label: rangeLabel, values: [
                MetricValue(number: quote.dayLow, kind: .price),
                MetricValue(number: quote.dayHigh, kind: .price)
            ])
        ]
    }
}
