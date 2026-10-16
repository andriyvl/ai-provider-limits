import Foundation

private struct RateLimitCooldown: Sendable {
    let provider: ProviderType
    let reference: CredentialReference?
    let candidate: CredentialCandidate?
    let until: Date

    func matches(candidate: CredentialCandidate, for provider: ProviderType) -> Bool {
        guard self.provider == provider else { return false }
        if let reference, let candidateRef = candidate.reference {
            return reference == candidateRef
        }
        if let storedCandidate = self.candidate {
            return storedCandidate.matchesCredential(candidate)
        }
        return false
    }
}

public actor SyncEngine {
    private let store: AppGroupStore
    private let resolver: CredentialResolver
    private let clock: @Sendable () -> Date

    private var clients: [ProviderType: any AIProviderClient] = [:]
    private var selections: [ProviderType: CredentialSelection] = [:]
    private var refreshGenerations: [ProviderType: Int] = [:]
    private var currentSnapshotsByProvider: [ProviderType: ProviderUsageSnapshot] = [:]
    private var currentCandidatesByProvider: [ProviderType: CredentialCandidate] = [:]
    private var rateLimitCooldowns: [RateLimitCooldown] = []

    public init(
        store: AppGroupStore = .shared,
        resolver: CredentialResolver = CredentialResolver(),
        session: URLSession = .shared,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.resolver = resolver
        self.clock = clock
        self.selections = store.loadCredentialSelections()
        self.clients = [
            .antigravity: AntigravityProvider(resolver: resolver, session: session),
            .codex: CodexProvider(resolver: resolver, session: session),
            .claude: ClaudeProvider(resolver: resolver, session: session),
            .cursor: CursorProvider(resolver: resolver, session: session),
            .openRouter: OpenRouterProvider(resolver: resolver, session: session)
        ]
    }

    public func register(client: any AIProviderClient) {
        clients[client.providerType] = client
    }

    public func setCredentialSelection(_ selection: CredentialSelection, for provider: ProviderType) async {
        selections[provider] = selection
        store.saveCredentialSelections(selections)
        refreshGenerations[provider, default: 0] += 1
        currentSnapshotsByProvider.removeValue(forKey: provider)
        currentCandidatesByProvider.removeValue(forKey: provider)
    }

    public func credentialSelections() async -> [ProviderType: CredentialSelection] {
        selections
    }

    public func discoverCredentials(for provider: ProviderType) async -> CredentialDiscovery {
        if let client = clients[provider] {
            return await client.credentialResolver.discover(provider: provider)
        }
        return await resolver.discover(provider: provider)
    }

    public func currentSnapshots() async -> [ProviderType: ProviderUsageSnapshot] {
        currentSnapshotsByProvider
    }

    public func cachedSnapshot(for provider: ProviderType) async -> ProviderUsageSnapshot? {
        let startGeneration = refreshGenerations[provider, default: 0]
        let selection = selections[provider] ?? .automatic
        guard let client = clients[provider] else { return nil }
        let resolution = await client.credentialResolver.resolve(provider: provider, selection: selection)
        guard refreshGenerations[provider, default: 0] == startGeneration,
              (selections[provider] ?? .automatic) == selection else {
            return nil
        }
        return eligibleCachedSnapshot(for: provider, candidates: resolution.candidates)
    }

    public func allCachedSnapshots() async -> [ProviderType: ProviderUsageSnapshot] {
        var startGenerations: [ProviderType: Int] = [:]
        for provider in ProviderType.allCases {
            startGenerations[provider] = refreshGenerations[provider, default: 0]
        }
        var results: [ProviderType: ProviderUsageSnapshot] = [:]
        for provider in ProviderType.allCases {
            if let cached = await cachedSnapshot(for: provider) {
                results[provider] = cached
            }
        }
        var verified: [ProviderType: ProviderUsageSnapshot] = [:]
        for (provider, snapshot) in results {
            if refreshGenerations[provider, default: 0] == startGenerations[provider] {
                verified[provider] = snapshot
            }
        }
        return verified
    }

    private func eligibleCachedSnapshot(
        for provider: ProviderType,
        candidates: [CredentialCandidate]
    ) -> ProviderUsageSnapshot? {
        let cachedByRef = store.loadSnapshots(for: provider)
        var newest: ProviderUsageSnapshot?
        var newestDate: Date?

        for candidate in candidates {
            guard let ref = candidate.reference, let cached = cachedByRef[ref] else { continue }
            let date = cached.provenance?.originalFetchedAt ?? cached.fetchedAt
            if let currentNewestDate = newestDate {
                if date > currentNewestDate {
                    newest = cached
                    newestDate = date
                }
            } else {
                newest = cached
                newestDate = date
            }
        }

        guard let newest, let prov = newest.provenance else { return nil }
        return newest.withProvenance(prov.withOrigin(.appCache))
    }

    private func matchingCachedSnapshot(
        for candidate: CredentialCandidate,
        provider: ProviderType
    ) -> ProviderUsageSnapshot? {
        guard let ref = candidate.reference,
              let cached = store.loadSnapshot(for: provider, reference: ref),
              let prov = cached.provenance else {
            return nil
        }
        return cached.withProvenance(prov.withOrigin(.appCache))
    }

    private func hasActiveCooldown(
        for candidate: CredentialCandidate,
        provider: ProviderType
    ) -> RateLimitCooldown? {
        rateLimitCooldowns.first { $0.matches(candidate: candidate, for: provider) && $0.until > clock() }
    }

    private func recordCooldown(
        for candidate: CredentialCandidate,
        provider: ProviderType,
        until: Date
    ) {
        rateLimitCooldowns.removeAll { $0.matches(candidate: candidate, for: provider) }
        let entry = RateLimitCooldown(
            provider: provider,
            reference: candidate.reference,
            candidate: candidate.reference == nil ? candidate : nil,
            until: until
        )
        rateLimitCooldowns.append(entry)
    }

    private func clearCooldown(
        for candidate: CredentialCandidate,
        provider: ProviderType
    ) {
        rateLimitCooldowns.removeAll { $0.matches(candidate: candidate, for: provider) }
    }

    public func refresh(provider: ProviderType) async throws -> ProviderUsageSnapshot {
        let generation = refreshGenerations[provider, default: 0] + 1
        refreshGenerations[provider] = generation

        guard let client = clients[provider] else {
            throw ProviderClientError.missingCredentials(provider)
        }

        let selection = selections[provider] ?? .automatic
        let resolution = await client.credentialResolver.resolve(provider: provider, selection: selection)
        guard refreshGenerations[provider] == generation else { throw CancellationError() }

        guard !resolution.candidates.isEmpty else {
            guard refreshGenerations[provider] == generation else { throw CancellationError() }
            let empty = ProviderUsageSnapshot.empty(for: provider)
            currentSnapshotsByProvider[provider] = empty
            currentCandidatesByProvider.removeValue(forKey: provider)
            return empty
        }

        if let currentCand = currentCandidatesByProvider[provider], currentCand.reference == nil {
            let stillEligible = resolution.candidates.contains { $0.matchesCredential(currentCand) }
            if !stillEligible {
                currentSnapshotsByProvider.removeValue(forKey: provider)
                currentCandidatesByProvider.removeValue(forKey: provider)
                rateLimitCooldowns.removeAll { $0.provider == provider && $0.reference == nil }
            }
        }

        let firstCoolingIndex = resolution.candidates.firstIndex { candidate in
            hasActiveCooldown(for: candidate, provider: provider) != nil
        }

        if firstCoolingIndex == 0 {
            let coolingCandidate = resolution.candidates[0]
            if let cached = matchingCachedSnapshot(for: coolingCandidate, provider: provider) {
                guard refreshGenerations[provider] == generation else { throw CancellationError() }
                currentSnapshotsByProvider[provider] = cached
                currentCandidatesByProvider[provider] = coolingCandidate
                return cached
            }
            guard refreshGenerations[provider] == generation else { throw CancellationError() }
            let cooldown = hasActiveCooldown(for: coolingCandidate, provider: provider)
            let remaining = cooldown?.until.timeIntervalSince(clock())
            currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
            currentCandidatesByProvider.removeValue(forKey: provider)
            throw ProviderClientError.rateLimited(provider, remaining)
        }

        let tryableCandidates: [CredentialCandidate]
        let coolingCandidate: CredentialCandidate?
        if let coolingIndex = firstCoolingIndex {
            if provider == .codex {
                tryableCandidates = Array(resolution.candidates.prefix(coolingIndex))
                coolingCandidate = resolution.candidates[coolingIndex]
            } else {
                tryableCandidates = [resolution.candidates[0]]
                coolingCandidate = nil
            }
        } else {
            if provider == .codex {
                tryableCandidates = resolution.candidates
            } else {
                tryableCandidates = [resolution.candidates[0]]
            }
            coolingCandidate = nil
        }

        do {
            let fetchedSnapshot: ProviderUsageSnapshot
            if let usageClient = client as? CredentialUsageClient {
                let candidateResolution = CredentialResolution(
                    discovery: resolution.discovery,
                    candidates: tryableCandidates
                )
                fetchedSnapshot = try await usageClient.fetchResolvedUsage(resolution: candidateResolution)
            } else {
                let rawSnapshot = try await client.fetchUsage(selection: selection)
                guard let prov = rawSnapshot.provenance,
                      resolution.candidates.contains(where: { candidate in
                          if let ref = candidate.reference, let provRef = prov.reference {
                              return ref == provRef && candidate.sourceID == prov.sourceID
                          }
                          return candidate.sourceID == prov.sourceID
                      }) else {
                    throw ProviderClientError.invalidResponse(provider, "Missing usage provenance")
                }
                fetchedSnapshot = rawSnapshot
            }

            guard refreshGenerations[provider] == generation else { throw CancellationError() }

            var finalSnapshot = fetchedSnapshot
            if finalSnapshot.isActive, finalSnapshot.metrics.isEmpty,
               let ref = finalSnapshot.provenance?.reference,
               let cached = store.loadSnapshot(for: provider, reference: ref),
               let provenance = cached.provenance,
               cached.isActive, !cached.metrics.isEmpty {
                finalSnapshot = cached.withProvenance(provenance.withOrigin(.appCache))
            }

            if finalSnapshot.provenance?.reference != nil {
                try? store.saveSnapshot(finalSnapshot)
            }

            if let successfulCandidate = tryableCandidates.first(where: { candidate in
                if let ref = candidate.reference, let provRef = finalSnapshot.provenance?.reference {
                    return ref == provRef
                }
                return candidate.sourceID == finalSnapshot.provenance?.sourceID
            }) {
                clearCooldown(for: successfulCandidate, provider: provider)
                currentCandidatesByProvider[provider] = successfulCandidate
            }

            currentSnapshotsByProvider[provider] = finalSnapshot
            return finalSnapshot

        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as CredentialRequestFailure {
            guard refreshGenerations[provider] == generation else { throw CancellationError() }
            if case .rateLimited = failure.reason {
                let cooldownUntil = clock().addingTimeInterval(900)
                recordCooldown(for: failure.candidate, provider: provider, until: cooldownUntil)
                if let cached = matchingCachedSnapshot(for: failure.candidate, provider: provider) {
                    currentSnapshotsByProvider[provider] = cached
                    currentCandidatesByProvider[provider] = failure.candidate
                    return cached
                }
                currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
                currentCandidatesByProvider.removeValue(forKey: provider)
                throw failure.reason
            }

            if let cooling = coolingCandidate {
                if let cached = matchingCachedSnapshot(for: cooling, provider: provider) {
                    currentSnapshotsByProvider[provider] = cached
                    currentCandidatesByProvider[provider] = cooling
                    return cached
                }
                let cooldown = hasActiveCooldown(for: cooling, provider: provider)
                let remaining = cooldown?.until.timeIntervalSince(clock())
                currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
                currentCandidatesByProvider.removeValue(forKey: provider)
                throw ProviderClientError.rateLimited(provider, remaining)
            }

            if let cached = eligibleCachedSnapshot(for: provider, candidates: resolution.candidates) {
                currentSnapshotsByProvider[provider] = cached
                return cached
            }
            currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
            currentCandidatesByProvider.removeValue(forKey: provider)
            throw ProviderClientError.networkError(provider, "Usage refresh failed. Try again.")

        } catch let providerError as ProviderClientError {
            guard refreshGenerations[provider] == generation else { throw CancellationError() }
            if case .rateLimited = providerError {
                if let candidate = tryableCandidates.first {
                    let cooldownUntil = clock().addingTimeInterval(900)
                    recordCooldown(for: candidate, provider: provider, until: cooldownUntil)
                    if let cached = matchingCachedSnapshot(for: candidate, provider: provider) {
                        currentSnapshotsByProvider[provider] = cached
                        currentCandidatesByProvider[provider] = candidate
                        return cached
                    }
                }
                currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
                currentCandidatesByProvider.removeValue(forKey: provider)
                throw providerError
            }

            if let cooling = coolingCandidate {
                if let cached = matchingCachedSnapshot(for: cooling, provider: provider) {
                    currentSnapshotsByProvider[provider] = cached
                    currentCandidatesByProvider[provider] = cooling
                    return cached
                }
                let cooldown = hasActiveCooldown(for: cooling, provider: provider)
                let remaining = cooldown?.until.timeIntervalSince(clock())
                currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
                currentCandidatesByProvider.removeValue(forKey: provider)
                throw ProviderClientError.rateLimited(provider, remaining)
            }

            if let cached = eligibleCachedSnapshot(for: provider, candidates: resolution.candidates) {
                currentSnapshotsByProvider[provider] = cached
                return cached
            }
            currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
            currentCandidatesByProvider.removeValue(forKey: provider)
            throw ProviderClientError.networkError(provider, "Usage refresh failed. Try again.")

        } catch {
            guard refreshGenerations[provider] == generation else { throw CancellationError() }
            if let cooling = coolingCandidate {
                if let cached = matchingCachedSnapshot(for: cooling, provider: provider) {
                    currentSnapshotsByProvider[provider] = cached
                    currentCandidatesByProvider[provider] = cooling
                    return cached
                }
                let cooldown = hasActiveCooldown(for: cooling, provider: provider)
                let remaining = cooldown?.until.timeIntervalSince(clock())
                currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
                currentCandidatesByProvider.removeValue(forKey: provider)
                throw ProviderClientError.rateLimited(provider, remaining)
            }
            if let cached = eligibleCachedSnapshot(for: provider, candidates: resolution.candidates) {
                currentSnapshotsByProvider[provider] = cached
                return cached
            }
            currentSnapshotsByProvider[provider] = ProviderUsageSnapshot.empty(for: provider)
            currentCandidatesByProvider.removeValue(forKey: provider)
            throw ProviderClientError.networkError(provider, "Usage refresh failed. Try again.")
        }
    }

    public func refreshAll(
        providers: [ProviderType] = ProviderType.allCases
    ) async -> [ProviderType: ProviderUsageSnapshot] {
        var startGenerations: [ProviderType: Int] = [:]
        for provider in providers {
            startGenerations[provider] = refreshGenerations[provider, default: 0]
        }
        await withTaskGroup(of: (ProviderType, ProviderUsageSnapshot?).self) { group in
            for provider in providers {
                group.addTask {
                    let snapshot = try? await self.refresh(provider: provider)
                    return (provider, snapshot)
                }
            }
            for await _ in group {}
        }
        var verifiedResults: [ProviderType: ProviderUsageSnapshot] = [:]
        for provider in providers {
            if refreshGenerations[provider, default: 0] == startGenerations[provider, default: 0] + 1,
               let current = currentSnapshotsByProvider[provider] {
                verifiedResults[provider] = current
            }
        }
        return verifiedResults
    }
}
