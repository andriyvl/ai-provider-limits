import Foundation

public struct ProviderUsageSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let provider: ProviderType
    public let planName: String
    public let fetchedAt: Date
    public let metrics: [LimitMetric]
    public let creditsRemaining: Double?
    public let onDemandSpend: Double?
    public let dailySpend: Double?
    public let isCreditOverageEnabled: Bool?
    public let isActive: Bool
    public let subscriptionEndsAt: Date?
    public let errorMessage: String?

    public init(
        id: String? = nil,
        provider: ProviderType,
        planName: String,
        fetchedAt: Date = Date(),
        metrics: [LimitMetric],
        creditsRemaining: Double? = nil,
        onDemandSpend: Double? = nil,
        dailySpend: Double? = nil,
        isCreditOverageEnabled: Bool? = nil,
        isActive: Bool = true,
        subscriptionEndsAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id ?? provider.rawValue
        self.provider = provider
        self.planName = planName
        self.fetchedAt = fetchedAt
        self.metrics = metrics
        self.creditsRemaining = creditsRemaining
        self.onDemandSpend = onDemandSpend
        self.dailySpend = dailySpend
        self.isCreditOverageEnabled = isCreditOverageEnabled
        self.isActive = isActive
        self.subscriptionEndsAt = subscriptionEndsAt
        self.errorMessage = errorMessage
    }

    public var hasError: Bool {
        errorMessage != nil
    }

    public var primaryMetric: LimitMetric? {
        metrics.first
    }

    public var subscriptionEndDate: Date? {
        subscriptionEndsAt
    }

    public func subscriptionDaysRemaining(relativeTo date: Date = Date()) -> Int? {
        guard let subscriptionEndDate else { return nil }
        return max(0, Int(ceil(subscriptionEndDate.timeIntervalSince(date) / 86_400)))
    }

    public func subscriptionStatus(relativeTo date: Date = Date()) -> SubscriptionStatus? {
        guard let daysRemaining = subscriptionDaysRemaining(relativeTo: date) else { return nil }
        switch daysRemaining {
        case 11...: return .healthy
        case 4...10: return .warning
        default: return .critical
        }
    }

    public static func empty(for provider: ProviderType) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: provider,
            planName: provider.displayName,
            metrics: [],
            creditsRemaining: nil,
            isCreditOverageEnabled: nil,
            isActive: true
        )
    }

    public static func sample(for provider: ProviderType) -> ProviderUsageSnapshot {
        empty(for: provider)
    }
}

public enum SubscriptionStatus: Sendable, Equatable {
    case healthy
    case warning
    case critical
}
