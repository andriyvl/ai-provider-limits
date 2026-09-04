import SwiftUI

public struct CircularProgressGaugeView: View {
    public let ratio: Double
    public let status: LimitStatus
    public let size: CGFloat
    public let lineWidth: CGFloat

    public init(ratio: Double, status: LimitStatus, size: CGFloat = 22.0, lineWidth: CGFloat = 3.5) {
        self.ratio = max(0.0, min(1.0, ratio))
        self.status = status
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(LiquidGlassTheme.track, lineWidth: lineWidth)

            Circle()
                .trim(from: 0.0, to: CGFloat(ratio))
                .stroke(
                    LiquidGlassTheme.statusColor(for: status),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: LiquidGlassTheme.statusColor(for: status).opacity(0.4), radius: 2, x: 0, y: 0)
        }
        .frame(width: size, height: size)
    }
}
