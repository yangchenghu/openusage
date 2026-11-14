import SwiftUI

/// The value text of an unbounded row. Identical to `WidgetData.unboundedDetail`, except that a signed
/// market change (a `.change` value, e.g. Crypto Prices' 24h move) is tinted green when up and red when
/// down, so direction reads at a glance next to the price.
struct UnboundedValueText: View {
    let data: WidgetData

    var body: some View {
        if let parts = data.priceChangeParts {
            let change = Text(parts.change).foregroundStyle(parts.isDown ? Theme.priceDown : Theme.priceUp)
            if parts.lead.isEmpty {
                change
            } else {
                Text("\(parts.lead) · ") + change
            }
        } else {
            Text(data.unboundedDetail)
        }
    }
}

extension WidgetData {
    /// The row split into its plain lead ("66,481.70") and its signed change ("-4.24%"), or `nil` when
    /// the row shows no `.change` value and renders as plain text.
    var priceChangeParts: (lead: String, change: String, isDown: Bool)? {
        guard hasData, valueTextOverride == nil else { return nil }
        let selected = selectedValues
        guard let change = selected.first(where: { $0.kind == .change }) else { return nil }
        let lead = selected.filter { $0.kind != .change }
            .map { MetricFormatter.string(for: $0, style: .row) }
            .joined(separator: " · ")
        return (lead, MetricFormatter.string(for: change, style: .row), change.number < 0)
    }
}
