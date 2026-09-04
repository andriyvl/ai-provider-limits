import SwiftUI

public struct MetricRowView: View {
    public let metric: LimitMetric
    public let showRemaining: Bool
    public let rowFill: Color

    public init(
        metric: LimitMetric,
        showRemaining: Bool = true,
        rowFill: Color = LiquidGlassTheme.rowBackground
    ) {
        self.metric = metric
        self.showRemaining = showRemaining
        self.rowFill = rowFill
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(headlineText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LiquidGlassTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                HorizontalProgressBarView(
                    ratio: metric.progressRatio,
                    status: metric.status,
                    height: 4.5
                )
                .frame(width: 78)

                ZStack(alignment: .trailing) {
                    Text("100% left")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .hidden()

                    Text(percentageText)
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(percentageColor)
                        .lineLimit(1)
                }
                .fixedSize()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(modelLineText)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(LiquidGlassTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !resetStatusText.isEmpty {
                    Text(resetStatusText)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(LiquidGlassTheme.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .liquidGlassRow(cornerRadius: 8, fill: rowFill)
    }

    private var headlineText: String {
        Self.formatHeadline(for: metric)
    }

    private var modelLineText: String {
        Self.formatModelLine(for: metric)
    }

    private var percentageText: String {
        if showRemaining {
            return "\(Int(metric.remainingPercentage))% left"
        } else {
            return "\(Int(metric.usedPercentage))% used"
        }
    }

    private var percentageColor: Color {
        LiquidGlassTheme.statusColor(for: metric.status)
    }

    private var resetStatusText: String {
        Self.formatResetStatus(for: metric)
    }

    public nonisolated static func resolveResetDate(
        for metric: LimitMetric,
        relativeTo baseDate: Date = Date()
    ) -> Date? {
        if let resetsAt = metric.resetsAt {
            return resetsAt
        }
        if let desc = metric.resetInDescription {
            return parseDurationToDate(desc, relativeTo: baseDate)
        }
        return nil
    }

    public nonisolated static func shortWindowName(from label: String) -> String? {
        let raw: String
        if let range = label.range(of: " · ") {
            raw = String(label[range.upperBound...])
        } else if label.contains("Limit") {
            raw = label
        } else {
            return nil
        }
        var name = raw
            .replacingOccurrences(of: " Usage Limit", with: "")
            .replacingOccurrences(of: " Session Window", with: "")
            .replacingOccurrences(of: " Limit", with: "")
        if name == "5-Hour" { name = "5 Hours" }
        return name
    }

    public nonisolated static func formatHeadline(
        for metric: LimitMetric,
        relativeTo baseDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = shortWindowName(from: metric.label)
        if let date = resolveResetDate(for: metric, relativeTo: baseDate) {
            let formatted = formatAbsoluteResetDate(date, relativeTo: baseDate, calendar: calendar)
            return window.map { "\($0) · \(formatted)" } ?? "Resets \(formatted)"
        }
        return window ?? metric.label
    }

    public nonisolated static func formatModelLine(for metric: LimitMetric) -> String {
        if let modelClass = metric.modelClass {
            return modelClass
        }
        return metric.label.contains("Limit") ? (metric.sublabel ?? "") : metric.label
    }

    public nonisolated static func formatResetStatus(
        for metric: LimitMetric,
        relativeTo baseDate: Date = Date()
    ) -> String {
        if let date = resolveResetDate(for: metric, relativeTo: baseDate) {
            let duration = compactDuration(until: date, from: baseDate)
            if duration == "Resets soon" || duration == "soon" {
                return "Resets soon"
            }
            return "\(duration) remaining"
        }
        if let resetDesc = metric.resetInDescription, !resetDesc.isEmpty {
            let duration = compactDurationText(resetDesc)
            if duration == "Resets soon" || duration == "soon" {
                return "Resets soon"
            }
            return "\(duration) remaining"
        }
        return ""
    }

    public nonisolated static func formatAbsoluteResetDate(
        _ date: Date,
        relativeTo baseDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeStyle = .short
        let timeString = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: baseDate) {
            return "Today, \(timeString)"
        }

        let startOfBase = calendar.startOfDay(for: baseDate)
        let startOfTarget = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startOfBase, to: startOfTarget).day ?? 0

        if dayDiff == 1 {
            return "Tmr, \(timeString)"
        }
        if dayDiff > 1 && dayDiff <= 6 {
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.calendar = calendar
            weekdayFormatter.dateFormat = "EEE"
            let weekday = weekdayFormatter.string(from: date)
            return "\(weekday), \(timeString)"
        }

        let currentYear = calendar.component(.year, from: baseDate)
        let targetYear = calendar.component(.year, from: date)

        let fullFormatter = DateFormatter()
        fullFormatter.calendar = calendar
        if currentYear == targetYear {
            fullFormatter.dateFormat = "MMM d"
            let datePrefix = fullFormatter.string(from: date)
            return "\(datePrefix), \(timeString)"
        } else {
            fullFormatter.dateFormat = "MMM d, yyyy"
            let datePrefix = fullFormatter.string(from: date)
            return "\(datePrefix), \(timeString)"
        }
    }

    public nonisolated static func compactDuration(until date: Date, from baseDate: Date = Date()) -> String {
        let interval = date.timeIntervalSince(baseDate)
        guard interval > 0 else { return "soon" }
        let days = Int(interval / 86400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else if minutes > 0 {
            return "\(minutes)m"
        }
        return "< 1m"
    }

    public nonisolated static func compactDurationText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["resets in ", "refresh in "]
        for prefix in prefixes where cleaned.lowercased().hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        if cleaned.lowercased().hasSuffix(" remaining") {
            cleaned = String(cleaned.dropLast(" remaining".count))
        }
        return cleaned
            .replacingOccurrences(of: " days", with: "d")
            .replacingOccurrences(of: " day", with: "d")
            .replacingOccurrences(of: " hours", with: "h")
            .replacingOccurrences(of: " hour", with: "h")
            .replacingOccurrences(of: " minutes", with: "m")
            .replacingOccurrences(of: " minute", with: "m")
            .replacingOccurrences(of: ", ", with: " ")
    }

    public nonisolated static func parseDurationToDate(_ text: String, relativeTo baseDate: Date = Date()) -> Date? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["resets in ", "refresh in ", "in "] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        if cleaned.hasSuffix(" remaining") {
            cleaned = String(cleaned.dropLast(" remaining".count))
        }

        var totalSeconds: TimeInterval = 0
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ", "))
        for part in parts where !part.isEmpty {
            if part.hasSuffix("d") || part.hasSuffix("day") || part.hasSuffix("days") {
                let digits = part.filter { $0.isNumber }
                if let val = Double(digits) { totalSeconds += val * 86400 }
            } else if part.hasSuffix("h") || part.hasSuffix("hr") || part.hasSuffix("hrs")
                || part.hasSuffix("hour") || part.hasSuffix("hours") {
                let digits = part.filter { $0.isNumber }
                if let val = Double(digits) { totalSeconds += val * 3600 }
            } else if part.hasSuffix("m") || part.hasSuffix("min") || part.hasSuffix("mins")
                || part.hasSuffix("minute") || part.hasSuffix("minutes") {
                let digits = part.filter { $0.isNumber }
                if let val = Double(digits) { totalSeconds += val * 60 }
            }
        }
        guard totalSeconds > 0 else { return nil }
        return baseDate.addingTimeInterval(totalSeconds)
    }
}
