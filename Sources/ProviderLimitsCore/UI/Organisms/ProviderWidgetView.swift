import SwiftUI

public enum WidgetDisplaySize: Sendable {
    case small
    case medium
    case large
}

public struct ProviderWidgetView: View {
    public let snapshot: ProviderUsageSnapshot
    public let size: WidgetDisplaySize
    public let isCard: Bool

    public init(
        snapshot: ProviderUsageSnapshot,
        size: WidgetDisplaySize = .medium,
        isCard: Bool = true
    ) {
        self.snapshot = snapshot
        self.size = size
        self.isCard = isCard
    }

    public var body: some View {
        let content = VStack(alignment: .leading, spacing: spacingForSize) {
            ProviderHeaderView(
                provider: snapshot.provider,
                planName: snapshot.planName,
                isActive: snapshot.isActive,
                subscriptionEndDate: snapshot.subscriptionEndDate,
                subscriptionDaysRemaining: snapshot.subscriptionDaysRemaining()
            )

            if visibleMetrics.isEmpty {
                HStack {
                    Text("Connecting...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiquidGlassTheme.textDim)
                    Spacer()
                    HorizontalProgressBarView(ratio: 0.0, status: .normal, height: 4.5)
                        .frame(width: 78)
                    ZStack(alignment: .trailing) {
                        Text("100% left")
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .hidden()
                        Text("--%")
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(LiquidGlassTheme.textDim)
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .liquidGlassRow(cornerRadius: 8, fill: rowFill)
            } else {
                VStack(alignment: .leading, spacing: metricSpacing) {
                    ForEach(visibleMetrics) { metric in
                        MetricRowView(metric: metric, rowFill: rowFill)
                    }
                    if size != .small {
                        ForEach(footerItems, id: \.title) { item in
                            footerRow(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)

        if isCard {
            content
                .padding(12)
                .liquidGlassCard(cornerRadius: 14, fill: cardFill)
        } else {
            content
        }
    }

    private var cardFill: Color {
        LiquidGlassTheme.cardBackground(for: snapshot.provider)
    }

    private var rowFill: Color {
        LiquidGlassTheme.rowBackground(for: snapshot.provider)
    }

    private var visibleMetrics: [LimitMetric] {
        let ordered = LimitMetric.displayOrder(snapshot.metrics)
        switch size {
        case .small:
            return Array(ordered.prefix(2))
        case .medium, .large:
            return ordered
        }
    }

    private var spacingForSize: CGFloat {
        switch size {
        case .small: return 6
        case .medium, .large: return 10
        }
    }

    private var metricSpacing: CGFloat {
        switch size {
        case .small: return 4
        case .medium, .large: return 6
        }
    }

    private var footerItems: [FooterItem] {
        var items: [FooterItem] = []
        if let credits = snapshot.creditsRemaining {
            let value = snapshot.provider == .cursor
                ? String(format: "$%.2f remaining", credits)
                : "\(Int(credits))"
            items.append(FooterItem(title: "Credits", value: value))
        }
        if let spend = snapshot.onDemandSpend, spend > 0 {
            items.append(FooterItem(title: "On-Demand Spend", value: String(format: "$%.2f", spend)))
        }
        if snapshot.isCreditOverageEnabled == true {
            items.append(FooterItem(title: "Overages", value: "Active"))
        }
        return items
    }

    private func footerRow(_ item: FooterItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(item.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LiquidGlassTheme.textPrimary)
            Spacer(minLength: 8)
            Text(item.value)
                .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                .foregroundStyle(LiquidGlassTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .liquidGlassRow(cornerRadius: 8, fill: rowFill)
    }
}

private struct FooterItem {
    let title: String
    let value: String
}
