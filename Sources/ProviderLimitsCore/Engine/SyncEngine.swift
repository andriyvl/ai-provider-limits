import Foundation

public actor SyncEngine {
    private let store: AppGroupStore
    private var clients: [ProviderType: any AIProviderClient] = [:]
    private var rateLimitCooldowns: [ProviderType: Date] = [:]

    public init(store: AppGroupStore = .shared) {
        self.store = store
        self.clients = [
            .antigravity: AntigravityProvider(),
            .codex: CodexProvider(),
            .claude: ClaudeProvider(),
            .cursor: CursorProvider()
        ]
    }

    public func register(client: any AIProviderClient) {
        clients[client.providerType] = client
    }

    public func refresh(provider: ProviderType) async throws -> ProviderUsageSnapshot {
        if let cooldownUntil = rateLimitCooldowns[provider], cooldownUntil > Date() {
            if let cached = store.loadSnapshot(for: provider) {
                return cached
            }
            throw ProviderClientError.rateLimited(provider, cooldownUntil.timeIntervalSinceNow)
        }

        guard let client = clients[provider] else {
            throw ProviderClientError.missingCredentials(provider)
        }

        do {
            let snapshot = try await client.fetchUsage()
            if snapshot.isActive, snapshot.metrics.isEmpty, let cached = store.loadSnapshot(for: provider) {
                return cached
            }
            try? store.saveSnapshot(snapshot)
            rateLimitCooldowns.removeValue(forKey: provider)
            return snapshot
        } catch let error as ProviderClientError {
            if case .rateLimited = error {
                rateLimitCooldowns[provider] = Date().addingTimeInterval(900)
            }
            if let cached = store.loadSnapshot(for: provider) {
                return cached
            }
            throw error
        } catch {
            if let cached = store.loadSnapshot(for: provider) {
                return cached
            }
            throw ProviderClientError.networkError(provider, error.localizedDescription)
        }
    }

    public func refreshAll(
        providers: [ProviderType] = ProviderType.allCases
    ) async -> [ProviderType: ProviderUsageSnapshot] {
        var results: [ProviderType: ProviderUsageSnapshot] = [:]
        await withTaskGroup(of: (ProviderType, ProviderUsageSnapshot?).self) { group in
            for provider in providers {
                group.addTask {
                    let snapshot = try? await self.refresh(provider: provider)
                    return (provider, snapshot)
                }
            }
            for await (provider, snapshot) in group {
                if let snapshot {
                    results[provider] = snapshot
                }
            }
        }
        return results
    }

    public func cachedSnapshot(for provider: ProviderType) -> ProviderUsageSnapshot? {
        store.loadSnapshot(for: provider)
    }

    public func allCachedSnapshots() -> [ProviderType: ProviderUsageSnapshot] {
        store.loadSnapshots()
    }
}
