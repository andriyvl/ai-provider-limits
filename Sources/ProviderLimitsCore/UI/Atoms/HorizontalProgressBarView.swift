import SwiftUI

public struct HorizontalProgressBarView: View {
    public let ratio: Double
    public let status: LimitStatus
    public let height: CGFloat

    public init(ratio: Double, status: LimitStatus, height: CGFloat = 4.5) {
        self.ratio = max(0.0, min(1.0, ratio))
        self.status = status
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            let barWidth = geometry.size.width
            let fillWidth = max(0, min(barWidth, barWidth * CGFloat(ratio)))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LiquidGlassTheme.track)
                    .frame(height: height)

                if ratio > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    LiquidGlassTheme.statusColor(for: status),
                                    LiquidGlassTheme.statusColor(for: status).opacity(0.85)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(height, fillWidth), height: height)
                        .shadow(color: LiquidGlassTheme.statusColor(for: status).opacity(0.3), radius: 2, x: 0, y: 0)
                }
            }
        }
        .frame(height: height)
    }
}
