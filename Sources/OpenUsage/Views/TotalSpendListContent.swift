import SwiftUI

/// Shared by the dashboard and its screenshot export. Provider order follows the dashboard rather
/// than changing with spend, so cost and token counts remain easy to compare across periods.
struct TotalSpendListContent: View {
    let total: TotalSpend

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: density.textRowPadding) {
            GridRow {
                Text("Provider")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Cost")
                    .gridColumnAlignment(.trailing)
                Text("Tokens")
                    .gridColumnAlignment(.trailing)
            }
            .font(.system(size: density.supportingPointSize - 1, weight: .medium))
            .foregroundStyle(.secondary)

            ForEach(total.slices) { slice in
                GridRow {
                    Text(slice.provider.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(cost(slice.amountUSD, available: slice.hasCostData, estimated: slice.estimated))
                    Text(tokens(slice.tokenCount, available: slice.hasTokenData))
                }
                .accessibilityElement(children: .combine)
            }

            Divider()
                .gridCellUnsizedAxes(.horizontal)

            GridRow {
                Text("Total")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(cost(total.totalUSD, available: total.slices.contains(where: \.hasCostData),
                          estimated: total.isEstimated))
                Text(tokens(total.totalTokens, available: total.slices.contains(where: \.hasTokenData)))
            }
            .fontWeight(.semibold)
        }
        .font(.system(size: density.supportingPointSize))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }

    private func cost(_ value: Double, available: Bool, estimated: Bool) -> String {
        guard available else { return "—" }
        return (estimated ? "~" : "") + MetricFormatter.number(value, kind: .dollars, style: .row)
    }

    private func tokens(_ value: Double, available: Bool) -> String {
        guard available else { return "—" }
        return MetricFormatter.number(value, kind: .count, style: .row)
    }
}
