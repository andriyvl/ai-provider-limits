import Foundation
import ProviderLimitsCore

@main
struct ProviderLimitsCLI {
    static func main() async {
        let engine = SyncEngine()
        let snapshots = await engine.refreshAll()

        print("\n╔════════════════════════════════════════════════════════════════════════╗")
        print("║                       AI PROVIDER LIMITS PREVIEW                       ║")
        print("╚════════════════════════════════════════════════════════════════════════╝\n")

        for provider in ProviderType.allCases {
            let snapshot = snapshots[provider] ?? ProviderUsageSnapshot.empty(for: provider)
            print("┌────────────────────────────────────────────────────────────────────────┐")
            let header = "│ [\(provider.systemIconName)] \(provider.displayName)"
            let planBadge = "[\(snapshot.planName)] │"
            let paddingCount = max(1, 74 - header.count - planBadge.count)
            print("\(header)\(String(repeating: " ", count: paddingCount))\(planBadge)")
            print("├────────────────────────────────────────────────────────────────────────┤")

            if snapshot.metrics.isEmpty {
                print("│  No active limit metrics found                                          │")
            } else {
                for metric in snapshot.metrics {
                    let label = metric.label
                    let pct = "\(Int(metric.remainingPercentage))% remaining"
                    let topPadding = max(1, 70 - label.count - pct.count)
                    print("│  \(label)\(String(repeating: " ", count: topPadding))\(pct)  │")

                    let barWidth = 66
                    let filledCount = Int(Double(barWidth) * (metric.remainingPercentage / 100.0))
                    let emptyCount = max(0, barWidth - filledCount)
                    let bar = String(repeating: "█", count: filledCount) + String(repeating: "░", count: emptyCount)
                    print("│  [\(bar)]  │")

                    if let reset = metric.resetInDescription, !reset.isEmpty {
                        let resetLine = "│  └─ \(reset)"
                        let resetPadding = max(1, 73 - resetLine.count)
                        print("\(resetLine)\(String(repeating: " ", count: resetPadding))│")
                    }
                }
            }

            if let credits = snapshot.creditsRemaining, credits > 0 {
                let creditLine = snapshot.provider == .cursor
                    ? String(format: "│  Credits remaining: $%.2f", credits)
                    : "│  Credits remaining: \(Int(credits))"
                let creditPadding = max(1, 73 - creditLine.count)
                print("\(creditLine)\(String(repeating: " ", count: creditPadding))│")
            }
            if let dailySpend = snapshot.dailySpend {
                let dailyLine = String(format: "│  Today's Usage (UTC): $%.2f", dailySpend)
                let dailyPadding = max(1, 73 - dailyLine.count)
                print("\(dailyLine)\(String(repeating: " ", count: dailyPadding))│")
            }
            if let spend = snapshot.onDemandSpend, spend > 0 {
                let spendLine = String(format: "│  On-Demand Spend: $%.2f", spend)
                let spendPadding = max(1, 73 - spendLine.count)
                print("\(spendLine)\(String(repeating: " ", count: spendPadding))│")
            }

            print("└────────────────────────────────────────────────────────────────────────┘\n")
        }
    }
}
