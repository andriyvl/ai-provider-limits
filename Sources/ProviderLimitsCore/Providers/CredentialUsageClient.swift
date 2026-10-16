import Foundation

protocol CredentialUsageClient: AIProviderClient {
    func fetchUsage(using candidate: CredentialCandidate) async throws -> ProviderUsageSnapshot
}

struct CredentialRequestFailure: Error, LocalizedError, Sendable {
    let candidate: CredentialCandidate
    let reason: ProviderClientError

    var errorDescription: String? { reason.errorDescription }
}

extension CredentialUsageClient {
    func fetchSelectedUsage(selection: CredentialSelection) async throws -> ProviderUsageSnapshot {
        let resolution = await credentialResolver.resolve(provider: providerType, selection: selection)
        return try await fetchResolvedUsage(resolution: resolution)
    }

    func fetchResolvedUsage(resolution: CredentialResolution) async throws -> ProviderUsageSnapshot {
        guard !resolution.candidates.isEmpty else { return .empty(for: providerType) }
        let candidateCount = providerType == .codex ? resolution.candidates.count : 1
        var lastFailure: CredentialRequestFailure?
        for candidate in resolution.candidates.prefix(candidateCount) {
            try Task.checkCancellation()
            do {
                let snapshot = try await fetchUsage(using: candidate)
                let descriptor = resolution.discovery.sources.first { $0.id == candidate.sourceID }
                let account = descriptor?.accounts.first { $0.reference == candidate.reference }
                return snapshot.withProvenance(UsageProvenance(
                    sourceID: candidate.sourceID, sourceLabel: descriptor?.label ?? "Credential source",
                    reference: candidate.reference, accountLabel: account?.label, origin: .live,
                    originalFetchedAt: snapshot.fetchedAt
                ))
            } catch {
                if error is CancellationError { throw error }
                let reason: ProviderClientError
                if let providerError = error as? ProviderClientError, case .rateLimited = providerError {
                    reason = .rateLimited(providerType, nil)
                } else {
                    reason = .networkError(providerType, "Usage refresh failed. Try again.")
                }
                let failure = CredentialRequestFailure(candidate: candidate, reason: reason)
                if case .rateLimited = reason { throw failure }
                lastFailure = failure
            }
        }
        if let lastFailure { throw lastFailure }
        return .empty(for: providerType)
    }
}

extension CredentialCandidate {
    func matchesCredential(_ other: CredentialCandidate) -> Bool {
        guard sourceID == other.sourceID else { return false }
        if let reference { return reference == other.reference }
        guard other.reference == nil else { return false }
        switch (payload, other.payload) {
        case let (.nativeAntigravity(left), .nativeAntigravity(right)):
            return left.accessToken == right.accessToken && left.isGCPTOS == right.isGCPTOS
                && left.expiresAt == right.expiresAt
        case let (.antigravity(left), .antigravity(right)):
            return left.accessToken == right.accessToken && left.projectId == right.projectId
        case let (.codex(left), .codex(right)):
            return left.accessToken == right.accessToken && left.accountId == right.accountId
        case let (.claude(left), .claude(right)):
            return left.accessToken == right.accessToken && left.subscriptionType == right.subscriptionType
        case let (.cursor(left), .cursor(right)):
            return left.accessToken == right.accessToken && left.userId == right.userId
                && left.membershipType == right.membershipType
        case let (.openRouter(left), .openRouter(right)):
            return left == right
        default:
            return false
        }
    }
}
