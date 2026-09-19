import SwiftUI

public struct ProviderHeaderView: View {
    public let provider: ProviderType
    public let planName: String
    public let isActive: Bool
    public let subscriptionEndDate: Date?
    public let subscriptionDaysRemaining: Int?

    public init(
        provider: ProviderType,
        planName: String = "",
        isActive: Bool = true,
        subscriptionEndDate: Date? = nil,
        subscriptionDaysRemaining: Int? = nil
    ) {
        self.provider = provider
        self.planName = planName
        self.isActive = isActive
        self.subscriptionEndDate = subscriptionEndDate
        self.subscriptionDaysRemaining = subscriptionDaysRemaining
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ProviderLogoView(provider: provider, size: 19)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(provider.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.textPrimary)

                if let displayPlan = formattedPlanName {
                    Text("(\(displayPlan))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LiquidGlassTheme.textSecondary)
                }
            }
            .lineLimit(1)
            Spacer()

            if isActive {
                Text(subscriptionEndDate.map { "till \(shortDate(for: $0))" } ?? "Active")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(statusColor.opacity(0.18))
                    )
            }
        }
    }

    public var formattedPlanName: String? {
        Self.formatPlanName(planName, for: provider)
    }

    nonisolated public static func formatPlanName(_ planName: String, for provider: ProviderType) -> String? {
        guard !planName.isEmpty else { return nil }
        let cleaned = planName
            .replacingOccurrences(of: " / Codex", with: "")
            .replacingOccurrences(of: "Included in ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned.caseInsensitiveCompare(provider.displayName) == .orderedSame {
            return nil
        }
        return cleaned
    }

    private func shortDate(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private var statusColor: Color {
        switch subscriptionDaysRemaining {
        case .some(11...): return LiquidGlassTheme.accent
        case .some(4...10): return LiquidGlassTheme.warning
        case .some: return LiquidGlassTheme.danger
        case nil: return LiquidGlassTheme.activeBadgeText
        }
    }
}
