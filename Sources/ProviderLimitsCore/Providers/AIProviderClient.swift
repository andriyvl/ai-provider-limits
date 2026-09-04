import Foundation

public protocol AIProviderClient: Sendable {
    var providerType: ProviderType { get }
    func fetchUsage() async throws -> ProviderUsageSnapshot
}

public enum ProviderClientError: Error, LocalizedError, Sendable {
    case missingCredentials(ProviderType)
    case invalidResponse(ProviderType, String)
    case networkError(ProviderType, String)
    case rateLimited(ProviderType, TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let provider):
            return "Missing credentials for \(provider.displayName)"
        case .invalidResponse(let provider, let reason):
            return "Invalid response from \(provider.displayName): \(reason)"
        case .networkError(let provider, let message):
            return "Network error connecting to \(provider.displayName): \(message)"
        case .rateLimited(let provider, _):
            return "Rate limited by \(provider.displayName)"
        }
    }
}
