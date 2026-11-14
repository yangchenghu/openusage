import SwiftUI

/// The summary export reuses the live provider list and totals, with the selected period in its header.
struct TotalSpendShareCardView: View {
    let total: TotalSpend
    let appearance: ColorScheme

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            DashboardMetricCard {
                TotalSpendListContent(total: total)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Usage Summary")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(total.period.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
