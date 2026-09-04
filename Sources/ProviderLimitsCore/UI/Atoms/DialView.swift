import SwiftUI

private struct DialArcShape: Shape {
    let fraction: Double
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2.0 - inset
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        return path
    }
}

public struct DialView: View {
    public let title: String
    public let ratio: Double
    public let status: LimitStatus
    public let resetText: String?
    public let size: CGFloat

    public init(
        title: String,
        ratio: Double,
        status: LimitStatus,
        resetText: String? = nil,
        size: CGFloat = 76.0
    ) {
        self.title = title
        self.ratio = max(0.0, min(1.0, ratio))
        self.status = status
        self.resetText = resetText
        self.size = size
    }

    private var scale: CGFloat {
        size / 76.0
    }

    private var arcWidth: CGFloat {
        4.5 * scale
    }

    private var arcInset: CGFloat {
        arcWidth / 2.0
    }

    private var statusColor: Color {
        LiquidGlassTheme.statusColor(for: status)
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(LiquidGlassTheme.track, lineWidth: arcWidth)
                .padding(arcInset)

            if ratio > 0.005 {
                DialArcShape(fraction: ratio, inset: arcInset + arcWidth / 2.0)
                    .stroke(
                        statusColor,
                        style: StrokeStyle(lineWidth: arcWidth, lineCap: .round)
                    )
                    .shadow(color: statusColor.opacity(0.35), radius: 2, x: 0, y: 0)
                    .animation(.easeOut(duration: 0.35), value: ratio)
            }

            VStack(spacing: 1.5 * scale) {
                Text(title.uppercased())
                    .font(.system(size: 8.0 * scale, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("\(Int(ratio * 100))%")
                    .font(.system(size: 14.5 * scale, weight: .bold).monospacedDigit())
                    .foregroundStyle(LiquidGlassTheme.textPrimary)
                    .lineLimit(1)

                Text(cleanResetText)
                    .font(.system(size: 7.5 * scale, weight: .medium))
                    .foregroundStyle(LiquidGlassTheme.textDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 6 * scale)
        }
        .frame(width: size, height: size)
    }

    private var cleanResetText: String {
        guard let resetText, !resetText.isEmpty else {
            return "ready"
        }
        var text = resetText
        if text.lowercased().hasPrefix("resets in ") {
            text = String(text.dropFirst(10))
        } else if text.lowercased().hasPrefix("resets ") {
            text = String(text.dropFirst(7))
        }
        return text
    }
}
