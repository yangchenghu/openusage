import AppKit
import SwiftUI

/// A compact cross-provider summary with cost and tokens shown together for the selected period.
/// Aggregates the same spend snapshots as the provider cards, including hidden spend metrics.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pickerNamespace

    /// The selected period survives popover closes and relaunches, like the meter-style toggles.
    @AppStorage(TotalSpendSetting.periodKey) private var periodRawValue = TotalSpendPeriod.today.rawValue
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private var period: TotalSpendPeriod {
        TotalSpendPeriod(rawValue: periodRawValue) ?? .today
    }

    /// The spend-tile providers the card may aggregate — capability-based (see
    /// `LayoutStore.spendCapableProviders`), so a provider stays counted even when its own rows are
    /// hidden in Customize, and providers with merely similar-looking dollar rows never leak in.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    private var total: TotalSpend {
        TotalSpendAggregator.total(for: period, providers: providers, snapshots: dataStore.snapshots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header
            card
        }
    }

    // MARK: - Header

    /// Section header matching the provider headers' scale: title leading, the share control
    /// trailing where a provider header shows its mark.
    private var header: some View {
        HStack(spacing: 5) {
            Text("Usage Summary")
                .font(.system(size: density.headerPointSize, weight: .semibold))
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(infoTooltip)
            Spacer(minLength: 8)
            shareButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }

    /// Names the providers actually feeding the summary — the enabled spend-capable set — instead of a
    /// hardcoded list, so disabling a provider (or a new spend provider shipping) can't make the
    /// tooltip lie about what the total reflects.
    private var infoTooltip: String {
        let names = providers.map(\.displayName)
        return "Only includes \(names.formatted(.list(type: .and)))."
    }

    private var shareButton: some View {
        CopyFeedbackButton(accessibilityLabel: "Copy Usage Summary Screenshot") {
            ShareCardRenderer.shareTotalSpend(
                total: total,
                appearance: colorScheme,
                layout: layout
            )
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 8) {
            periodPicker
            if total.isEmpty {
                emptyState
            } else {
                TotalSpendListContent(total: total)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .animation(Motion.spring, value: periodRawValue)
        .contextMenu {
            Button("Share Screenshot") {
                ShareCardRenderer.shareTotalSpend(
                    total: total,
                    appearance: colorScheme,
                    layout: layout
                )
            }
        }
    }

    /// A capsule segmented switcher in the app's own design language (the footer's glass capsule
    /// controls), replacing the stock `.segmented` picker whose legacy rounded-rect chrome clashes
    /// with the Tahoe look. The selected segment is a Liquid Glass capsule (frosted material on
    /// macOS 15) that slides between segments via `matchedGeometryEffect`.
    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(TotalSpendPeriod.allCases) { candidate in
                periodSegment(candidate)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private func periodSegment(_ candidate: TotalSpendPeriod) -> some View {
        let isSelected = candidate == period
        return Button {
            periodRawValue = candidate.rawValue
        } label: {
            Text(candidate.shortLabel)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .matchedGeometryEffect(id: "totalSpendPeriod", in: pickerNamespace)
            }
        }
        .animation(Motion.spring, value: periodRawValue)
    }

    /// An idle period stays explicit instead of showing fabricated zero totals.
    private var emptyState: some View {
        Text("No usage data for this period")
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}
