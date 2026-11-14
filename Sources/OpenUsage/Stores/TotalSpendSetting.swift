import Foundation

/// Whether the cross-provider usage summary shows at the top of the dashboard. On by default;
/// the toggle sits at the top of Settings → General. Hiding it only affects the card — the
/// per-provider spend rows it aggregates stay wherever the user put them.
enum TotalSpendSetting {
    static let key = "showTotalSpend"
    /// The card's selected period (Today / Yesterday / 30 Days), persisted by `TotalSpendCard`.
    static let periodKey = "openusage.totalSpend.period"
    /// Legacy metric preference, retained so Reset All Settings clears it on upgraded installs.
    static let metricKey = "openusage.totalSpend.metric"
}
