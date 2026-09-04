import SwiftUI

public enum LiquidGlassTheme {
    public static let panelBackground = Color(red: 0.12, green: 0.13, blue: 0.15)
    public static let cardBackground = Color(red: 0.17, green: 0.18, blue: 0.20)
    public static let rowBackground = Color(red: 0.22, green: 0.23, blue: 0.25)
    public static let track = Color.white.opacity(0.12)

    public static let textPrimary = Color.white.opacity(0.78)
    public static let textSecondary = Color.white.opacity(0.46)
    public static let textMuted = Color.white.opacity(0.34)
    public static let textDim = Color.white.opacity(0.24)

    public static let accent = Color(red: 0.32, green: 0.78, blue: 0.52)
    public static let warning = Color(red: 0.88, green: 0.70, blue: 0.32)
    public static let danger = Color(red: 0.88, green: 0.42, blue: 0.42)
    public static let info = Color(red: 0.48, green: 0.68, blue: 0.90)

    public static let activeBadgeText = Color(red: 0.38, green: 0.80, blue: 0.56)
    public static let activeBadgeBackground = Color(red: 0.18, green: 0.32, blue: 0.24)

    public static func statusColor(for status: LimitStatus) -> Color {
        switch status {
        case .normal:
            return accent
        case .warning:
            return warning
        case .critical, .depleted:
            return danger
        }
    }

    public static func providerColor(for provider: ProviderType) -> Color {
        switch provider {
        case .antigravity:
            return Color(red: 0.45, green: 0.68, blue: 0.98)
        case .codex:
            return Color(red: 0.38, green: 0.82, blue: 0.78)
        case .claude:
            return Color(red: 0.94, green: 0.62, blue: 0.42)
        case .cursor:
            return Color(red: 0.78, green: 0.56, blue: 0.94)
        }
    }

    public static func cardBackground(for provider: ProviderType) -> Color {
        switch provider {
        case .antigravity:
            return Color(red: 0.16, green: 0.22, blue: 0.34)
        case .codex:
            return Color(red: 0.14, green: 0.23, blue: 0.29)
        case .claude:
            return Color(red: 0.28, green: 0.18, blue: 0.14)
        case .cursor:
            return cardBackground
        }
    }

    public static func rowBackground(for provider: ProviderType) -> Color {
        switch provider {
        case .antigravity:
            return Color(red: 0.20, green: 0.27, blue: 0.40)
        case .codex:
            return Color(red: 0.18, green: 0.28, blue: 0.35)
        case .claude:
            return Color(red: 0.34, green: 0.23, blue: 0.18)
        case .cursor:
            return rowBackground
        }
    }
}

public struct LiquidGlassCardModifier: ViewModifier {
    public let cornerRadius: CGFloat
    public let fill: Color

    public init(cornerRadius: CGFloat = 14, fill: Color = LiquidGlassTheme.cardBackground) {
        self.cornerRadius = cornerRadius
        self.fill = fill
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
    }
}

public struct LiquidGlassRowModifier: ViewModifier {
    public let cornerRadius: CGFloat
    public let fill: Color

    public init(cornerRadius: CGFloat = 9, fill: Color = LiquidGlassTheme.rowBackground) {
        self.cornerRadius = cornerRadius
        self.fill = fill
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
    }
}

public extension View {
    func liquidGlassCard(
        cornerRadius: CGFloat = 14,
        fill: Color = LiquidGlassTheme.cardBackground
    ) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, fill: fill))
    }

    func liquidGlassRow(
        cornerRadius: CGFloat = 9,
        fill: Color = LiquidGlassTheme.rowBackground
    ) -> some View {
        modifier(LiquidGlassRowModifier(cornerRadius: cornerRadius, fill: fill))
    }
}
