import Foundation

public enum LimitStatus: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case depleted

    public static func evaluate(remainingPercentage: Double) -> LimitStatus {
        if remainingPercentage <= 0.0 {
            return .depleted
        } else if remainingPercentage < 15.0 {
            return .critical
        } else if remainingPercentage < 40.0 {
            return .warning
        } else {
            return .normal
        }
    }

    public static func evaluate(usedPercentage: Double) -> LimitStatus {
        if usedPercentage >= 100.0 {
            return .depleted
        } else if usedPercentage > 85.0 {
            return .critical
        } else if usedPercentage > 60.0 {
            return .warning
        } else {
            return .normal
        }
    }
}

public struct LimitMetric: Codable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let sublabel: String?
    public let usedPercentage: Double
    public let remainingPercentage: Double
    public let resetsAt: Date?
    public let resetInDescription: String?
    public let status: LimitStatus
    public let rawLimit: Double?
    public let rawUsed: Double?
    public let unit: String?

    public init(
        id: String,
        label: String,
        sublabel: String? = nil,
        usedPercentage: Double,
        remainingPercentage: Double,
        resetsAt: Date? = nil,
        resetInDescription: String? = nil,
        status: LimitStatus? = nil,
        rawLimit: Double? = nil,
        rawUsed: Double? = nil,
        unit: String? = nil
    ) {
        self.id = id
        self.label = label
        self.sublabel = sublabel
        self.usedPercentage = max(0.0, min(100.0, usedPercentage))
        self.remainingPercentage = max(0.0, min(100.0, remainingPercentage))
        self.resetsAt = resetsAt
        self.resetInDescription = resetInDescription
        self.status = status ?? LimitStatus.evaluate(remainingPercentage: self.remainingPercentage)
        self.rawLimit = rawLimit
        self.rawUsed = rawUsed
        self.unit = unit
    }

    public var progressRatio: Double {
        remainingPercentage / 100.0
    }

    public var usedRatio: Double {
        usedPercentage / 100.0
    }

    public var shortDialLabel: String {
        let lower = label.lowercased()
        if lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("5h") {
            return "5-Hour"
        } else if lower.contains("weekly") || lower.contains("7-day") || lower.contains("week") {
            return "Weekly"
        } else if lower.contains("claude") {
            return "Claude"
        } else if lower.contains("cursor") {
            return "Cursor"
        } else if lower.contains("other") {
            return "Other"
        } else if lower.contains("session") {
            return "Session"
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "·-:/"))
        let words = label.components(separatedBy: separators).filter { !$0.isEmpty }
        return words.first ?? label
    }

    public var modelClass: String? {
        guard let range = label.range(of: " · ") else { return nil }
        return String(label[..<range.lowerBound])
    }

    public var displayRank: Int {
        if id.contains("sonnet") { return 1 }
        if id.contains("weekly") || id.contains("seven_day") { return 0 }
        if id.contains("5hour") { return 2 }
        return 3
    }

    public static func displayOrder(_ metrics: [LimitMetric]) -> [LimitMetric] {
        var classOrder: [String?] = []
        var groups: [String?: [(offset: Int, metric: LimitMetric)]] = [:]
        for (offset, metric) in metrics.enumerated() {
            let key = metric.modelClass
            if groups[key] == nil { classOrder.append(key) }
            groups[key, default: []].append((offset, metric))
        }
        return classOrder.flatMap { key in
            groups[key]!
                .sorted { lhs, rhs in
                    let leftRank = lhs.metric.displayRank
                    let rightRank = rhs.metric.displayRank
                    return leftRank != rightRank ? leftRank < rightRank : lhs.offset < rhs.offset
                }
                .map(\.metric)
        }
    }
}
