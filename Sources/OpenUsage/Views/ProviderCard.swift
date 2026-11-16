import SwiftUI

/// The grouped metric-card body shared by the live dashboard list and its lifted drag preview:
/// a spacing-0 stack of rows (separated by row padding, never dividers), the density gutter that
/// keeps the first/last row off the card edge, and the shared card surface. Both surfaces build the
/// card through this so the floating preview can't drift from the live card (it once hard-coded its
/// spacing and even drew dividers the live list doesn't).
///
/// The live list threads per-row gestures/opacity/frames through `rows`; the preview passes plain
/// `WidgetRowView`s; the preview's shadow supplies its lifted depth.
struct DashboardMetricCard<Rows: View>: View {
    @ViewBuilder var rows: Rows

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(spacing: 0) {
            rows
        }
        .padding(.vertical, density.cardGutter)
        .cardSurface()
    }
}

struct DashboardMetricCardSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }
}

/// Expand/collapse control at the trailing edge of a provider header, to the right of the
/// hover-revealed copy button. Always visible, so the card doesn't spend a row on it. Points down
/// while collapsed and up while the On Demand section is open.
struct DashboardMetricCardCaret: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Same 16pt layout slot as `CopyFeedbackButton`: the glyphs line up, and the 28pt hit
        // rectangle doesn't make the header taller.
        .padding(-6)
        .accessibilityLabel(isExpanded ? "Show less" : "Show more")
    }
}
