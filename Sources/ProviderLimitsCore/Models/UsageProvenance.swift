import Foundation

public enum UsageDataOrigin: String, Codable, Sendable {
    case live
    case toolStored
    case appCache
}

public struct UsageProvenance: Codable, Equatable, Sendable {
    public let sourceID: String
    public let sourceLabel: String
    public let reference: CredentialReference?
    public let accountLabel: String?
    public let origin: UsageDataOrigin
    public let originalFetchedAt: Date

    public init(
        sourceID: String, sourceLabel: String, reference: CredentialReference?,
        accountLabel: String? = nil, origin: UsageDataOrigin, originalFetchedAt: Date
    ) {
        self.sourceID = sourceID
        self.sourceLabel = sourceLabel
        self.reference = reference
        self.accountLabel = accountLabel
        self.origin = origin
        self.originalFetchedAt = originalFetchedAt
    }

    public var displayLabel: String {
        [sourceLabel, accountLabel].compactMap { $0 }.joined(separator: " · ")
    }

    public func withOrigin(_ origin: UsageDataOrigin) -> UsageProvenance {
        UsageProvenance(
            sourceID: sourceID, sourceLabel: sourceLabel, reference: reference,
            accountLabel: accountLabel, origin: origin, originalFetchedAt: originalFetchedAt
        )
    }
}
