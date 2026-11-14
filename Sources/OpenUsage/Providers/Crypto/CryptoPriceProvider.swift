import Foundation

/// Crypto Prices: live USDT spot prices from OKX's public market API. No account or key is needed, so
/// it is always "detected" and refreshes on a short cadence of its own.
///
/// The coin list is read once at launch because it decides the widget descriptors (one price tile and
/// one 24h range tile per coin). Customize saves a changed list and restarts the app to apply it.
@MainActor
final class CryptoPriceProvider: ProviderRuntime {
    static let providerID = "crypto"
    static let refreshSeconds: TimeInterval = 15

    let provider = Provider(
        id: CryptoPriceProvider.providerID,
        displayName: "Crypto Prices",
        icon: .providerMark(CryptoPriceProvider.providerID)
    )

    let settings: CryptoPriceSettings
    private let client: OKXTickerClient
    private let now: @Sendable () -> Date

    init(
        settings: CryptoPriceSettings = .load(),
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.client = OKXTickerClient(apiBase: settings.apiBase, http: http)
        self.now = now
    }

    var refreshInterval: TimeInterval { Self.refreshSeconds }

    var widgetDescriptors: [WidgetDescriptor] {
        Self.descriptors(provider: provider, coins: settings.coins)
    }

    static func priceDescriptorID(_ coin: String) -> String { "crypto.\(coin.lowercased())" }
    static func rangeDescriptorID(_ coin: String) -> String { "crypto.\(coin.lowercased()).range" }

    static func descriptors(provider: Provider, coins: [String]) -> [WidgetDescriptor] {
        coins.flatMap { coin in
            [
                .values(id: priceDescriptorID(coin), provider: provider, title: coin,
                        metricLabel: CryptoPriceMapper.priceLabel(for: coin)),
                .values(id: rangeDescriptorID(coin), provider: provider, title: "\(coin) 24h Range",
                        metricLabel: CryptoPriceMapper.rangeLabel(for: coin), valueSeparator: " – ")
            ]
        }
    }

    /// Layout defaults for the configured coins: every tile enabled, the range tiles On Demand, and the
    /// first coin's price starred in the menu bar on a fresh install. Merged into `DefaultLayout` by
    /// `AppContainer` because the IDs depend on the coin list.
    static func defaultLayout(coins: [String]) -> (metricIDs: [String], expandedMetricIDs: [String], pinnedMetricIDs: [String]) {
        (
            metricIDs: coins.flatMap { [priceDescriptorID($0), rangeDescriptorID($0)] },
            expandedMetricIDs: coins.map(rangeDescriptorID),
            pinnedMetricIDs: coins.first.map { [priceDescriptorID($0)] } ?? []
        )
    }

    /// Public market data needs no credentials, so the welcome screen and new-provider detection always
    /// offer it.
    func hasLocalCredentials() async -> Bool { true }

    func refresh() async -> ProviderSnapshot {
        let results = await client.fetchQuotes(coins: settings.coins)
        if let error = CryptoPriceMapper.blockingError(coins: settings.coins, results: results) {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        let failed = settings.coins.filter {
            if case .failed = results[$0] { return true }
            return false
        }
        var warning: String?
        if !failed.isEmpty {
            AppLog.warn(LogTag.plugin("crypto"), "no quote this pass for \(failed.joined(separator: ", "))")
            warning = "Couldn't load \(failed.joined(separator: ", ")) this time."
        }
        return ProviderSnapshot.make(
            provider: provider,
            plan: "OKX · \(CryptoPriceSettings.quoteCurrency)",
            lines: CryptoPriceMapper.lines(coins: settings.coins, results: results),
            refreshedAt: now(),
            warning: warning
        )
    }
}
