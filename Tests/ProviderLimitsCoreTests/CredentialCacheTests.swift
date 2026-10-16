import Foundation
import SQLite3
import Testing
@testable import ProviderLimitsCore

@Suite("Credential Cache Tests", .serialized)
struct CredentialCacheTests {
    private let fixedDate = Date(timeIntervalSince1970: 1791316800)

    @Test("Same reference offline continuity returns app cache provenance")
    func sameReferenceOfflineContinuity() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let refA = CredentialReference(sourceID: "native.codex", accountID: "user-a")
            let provenance = UsageProvenance(
                sourceID: "native.codex",
                sourceLabel: "Codex",
                reference: refA,
                accountLabel: "user-a",
                origin: .live,
                originalFetchedAt: self.fixedDate.addingTimeInterval(-300)
            )
            let cached = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate.addingTimeInterval(-300),
                metrics: [
                    LimitMetric(
                        id: "rate",
                        label: "Rate Limit",
                        usedPercentage: 42,
                        remainingPercentage: 58
                    )
                ],
                isActive: true,
                provenance: provenance
            )
            try store.saveSnapshot(cached)

            let jwt = makeJWT(now: self.fixedDate.timeIntervalSince1970, accountID: "user-a")
            try writeCodexAuth(home: home, token: jwt, accountID: "user-a")

            StubTransport.setHandler { _ in
                throw URLError(.notConnectedToInternet)
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let result = try await engine.refresh(provider: .codex)

            #expect(result.provenance?.origin == .appCache)
            #expect(result.provenance?.reference == refA)
            #expect(result.metrics.first?.usedPercentage == 42)
        }
    }

    @Test("Active empty snapshot preserves cached metrics for same reference")
    func activeEmptySnapshotPreservesCachedMetrics() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let refA = CredentialReference(sourceID: "native.codex", accountID: "user-a")
            let provenance = UsageProvenance(
                sourceID: "native.codex",
                sourceLabel: "Codex",
                reference: refA,
                accountLabel: "user-a",
                origin: .live,
                originalFetchedAt: self.fixedDate.addingTimeInterval(-60)
            )
            let cached = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate.addingTimeInterval(-60),
                metrics: [
                    LimitMetric(
                        id: "rate",
                        label: "Rate Limit",
                        usedPercentage: 55,
                        remainingPercentage: 45
                    )
                ],
                isActive: true,
                provenance: provenance
            )
            try store.saveSnapshot(cached)

            let jwt = makeJWT(now: self.fixedDate.timeIntervalSince1970, accountID: "user-a")
            try writeCodexAuth(home: home, token: jwt, accountID: "user-a")

            StubTransport.setHandler { request in
                let json = """
                {
                  "plan_type": "ChatGPT Plus / Codex",
                  "credits_remaining": 0.0,
                  "rate_limit": []
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let result = try await engine.refresh(provider: .codex)

            #expect(result.metrics.count == 1)
            #expect(result.metrics.first?.usedPercentage == 55)
            #expect(result.provenance?.origin == .appCache)
        }
    }

    @Test("Pinned account refuses other identity cache")
    func pinnedAccountRefusesOtherIdentityCache() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let refB = CredentialReference(sourceID: "native.codex", accountID: "user-b")
            let cachedB = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate.addingTimeInterval(-100),
                metrics: [
                    LimitMetric(
                        id: "rate",
                        label: "Rate Limit",
                        usedPercentage: 30,
                        remainingPercentage: 70
                    )
                ],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "native.codex",
                    sourceLabel: "Codex",
                    reference: refB,
                    origin: .live,
                    originalFetchedAt: self.fixedDate.addingTimeInterval(-100)
                )
            )
            try store.saveSnapshot(cachedB)

            let jwtA = makeJWT(now: self.fixedDate.timeIntervalSince1970, accountID: "user-a")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")

            StubTransport.setHandler { _ in
                throw URLError(.notConnectedToInternet)
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            await engine.setCredentialSelection(.source("native.codex", accountID: "user-a"), for: .codex)

            do {
                _ = try await engine.refresh(provider: .codex)
                Issue.record("Expected network error when pinned account has no cache")
            } catch let error as ProviderClientError {
                if case .networkError = error {
                    
                } else {
                    Issue.record("Unexpected error: \(error)")
                }
            }
        }
    }

    @Test("Automatic returns eligible B cache when candidate A has no live response or cache")
    func automaticReturnsEligibleBCacheWhenAHasNoLiveOrCache() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refB = CredentialReference(sourceID: "omp.codex", accountID: "user-b")
            let cachedB = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate.addingTimeInterval(-120),
                metrics: [
                    LimitMetric(
                        id: "rate",
                        label: "Rate Limit",
                        usedPercentage: 70,
                        remainingPercentage: 30
                    )
                ],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "omp.codex",
                    sourceLabel: "Codex",
                    reference: refB,
                    accountLabel: "user-b",
                    origin: .live,
                    originalFetchedAt: self.fixedDate.addingTimeInterval(-120)
                )
            )
            try store.saveSnapshot(cachedB)

            let jwtA = makeJWT(now: now, accountID: "user-a")
            let jwtB = makeJWT(now: now + 500, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            StubTransport.setHandler { _ in
                throw URLError(.notConnectedToInternet)
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let result = try await engine.refresh(provider: .codex)

            #expect(result.provenance?.origin == .appCache)
            #expect(result.provenance?.reference == refB)
            #expect(result.metrics.first?.usedPercentage == 70)
        }
    }

    @Test("Newest timestamp cache wins among eligible candidates")
    func newestTimestampCacheWinsAmongEligibleCandidates() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refA = CredentialReference(sourceID: "native.codex", accountID: "user-a")
            let refB = CredentialReference(sourceID: "omp.codex", accountID: "user-b")

            let cachedA = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate.addingTimeInterval(-200),
                metrics: [LimitMetric(id: "rate", label: "Rate", usedPercentage: 10, remainingPercentage: 90)],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "native.codex",
                    sourceLabel: "Codex",
                    reference: refA,
                    origin: .live,
                    originalFetchedAt: self.fixedDate.addingTimeInterval(-200)
                )
            )
            let cachedB = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate.addingTimeInterval(-50),
                metrics: [LimitMetric(id: "rate", label: "Rate", usedPercentage: 90, remainingPercentage: 10)],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "omp.codex",
                    sourceLabel: "Codex",
                    reference: refB,
                    origin: .live,
                    originalFetchedAt: self.fixedDate.addingTimeInterval(-50)
                )
            )
            try store.saveSnapshot(cachedA)
            try store.saveSnapshot(cachedB)

            let jwtA = makeJWT(now: now, accountID: "user-a")
            let jwtB = makeJWT(now: now + 500, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            StubTransport.setHandler { _ in
                throw URLError(.notConnectedToInternet)
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let result = try await engine.refresh(provider: .codex)

            #expect(result.provenance?.reference == refB)
            #expect(result.metrics.first?.usedPercentage == 90)
        }
    }

    @Test("Equal timestamp ties broken deterministically by candidate order")
    func equalTimestampTiesBrokenByCandidateOrder() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refA = CredentialReference(sourceID: "native.codex", accountID: "user-a")
            let refB = CredentialReference(sourceID: "omp.codex", accountID: "user-b")
            let sameTimestamp = self.fixedDate.addingTimeInterval(-100)

            let cachedA = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: sameTimestamp,
                metrics: [LimitMetric(id: "rate", label: "Rate", usedPercentage: 11, remainingPercentage: 89)],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "native.codex",
                    sourceLabel: "Codex",
                    reference: refA,
                    origin: .live,
                    originalFetchedAt: sameTimestamp
                )
            )
            let cachedB = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: sameTimestamp,
                metrics: [LimitMetric(id: "rate", label: "Rate", usedPercentage: 22, remainingPercentage: 78)],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "omp.codex",
                    sourceLabel: "Codex",
                    reference: refB,
                    origin: .live,
                    originalFetchedAt: sameTimestamp
                )
            )
            try store.saveSnapshot(cachedA)
            try store.saveSnapshot(cachedB)

            let jwtA = makeJWT(now: now + 500, accountID: "user-a")
            let jwtB = makeJWT(now: now, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            StubTransport.setHandler { _ in
                throw URLError(.notConnectedToInternet)
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let result = try await engine.refresh(provider: .codex)

            #expect(result.provenance?.reference == refA)
            #expect(result.metrics.first?.usedPercentage == 11)
        }
    }

    @Test("Legacy unattributed cache excluded from lookup and refresh fallback")
    func legacyUnattributedCacheExcluded() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let snapshotsURL = store.containerDirectory.appendingPathComponent("snapshots.json")
            let legacySnapshot = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Legacy",
                fetchedAt: self.fixedDate.addingTimeInterval(-1000),
                metrics: [LimitMetric(id: "leg", label: "Legacy", usedPercentage: 99, remainingPercentage: 1)],
                isActive: true,
                provenance: nil
            )
            let legacyData = try JSONEncoder().encode(["codex": legacySnapshot])
            try legacyData.write(to: snapshotsURL)

            let refA = CredentialReference(sourceID: "native.codex", accountID: "user-a")
            #expect(store.loadSnapshot(for: .codex, reference: refA) == nil)

            let jwtA = makeJWT(now: self.fixedDate.timeIntervalSince1970, accountID: "user-a")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")

            StubTransport.setHandler { _ in
                throw URLError(.notConnectedToInternet)
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let cached = await engine.cachedSnapshot(for: .codex)
            #expect(cached == nil)

            do {
                _ = try await engine.refresh(provider: .codex)
                Issue.record("Expected failure when only legacy unattributed cache exists")
            } catch {
                
            }
        }
    }

    @Test("Unknown identity is never persisted to durable cache")
    func unknownIdentityNeverPersistedToDisk() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            try writeClaudeCredentials(home: home, token: "claude-token-unknown")

            StubTransport.setHandler { request in
                let json = """
                {
                  "plan_name": "Claude Pro",
                  "five_hour": {
                    "utilization": 20.0,
                    "resets_at": "2026-09-10T12:00:00Z"
                  },
                  "seven_day": null
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let liveResult = try await engine.refresh(provider: .claude)
            #expect(liveResult.isActive)

            let dummyRef = CredentialReference(sourceID: "native.claude", accountID: "dummy")
            #expect(store.loadSnapshot(for: .claude, reference: dummyRef) == nil)
            let cached = await engine.cachedSnapshot(for: .claude)
            #expect(cached == nil)
        }
    }

    @Test("Persisted JSON files are secret-free")
    func secretFreePersistedJSON() async throws {
        try await withTestEnvironment { store, _, _, _ in
            let ref = CredentialReference(sourceID: "native.codex", accountID: "user-safe")
            let snapshot = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate,
                metrics: [LimitMetric(id: "rate", label: "Rate", usedPercentage: 25, remainingPercentage: 75)],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "native.codex",
                    sourceLabel: "Codex",
                    reference: ref,
                    accountLabel: "Safe Label",
                    origin: .live,
                    originalFetchedAt: self.fixedDate
                )
            )
            try store.saveSnapshot(snapshot)
            store.saveCredentialSelections([.codex: .source("native.codex", accountID: "user-safe")])

            let snapshotsFile = store.containerDirectory.appendingPathComponent("snapshots.json")
            let selectionsFile = store.containerDirectory.appendingPathComponent("credential_selections.json")

            let snapshotsData = try Data(contentsOf: snapshotsFile)
            let selectionsData = try Data(contentsOf: selectionsFile)
            let snapshotsString = String(decoding: snapshotsData, as: UTF8.self)
            let selectionsString = String(decoding: selectionsData, as: UTF8.self)

            #expect(!snapshotsString.contains("accessToken"))
            #expect(!snapshotsString.contains("Bearer"))
            #expect(!snapshotsString.contains("secret"))
            #expect(!selectionsString.contains("accessToken"))
            #expect(!selectionsString.contains("Bearer"))
            #expect(!selectionsString.contains("secret"))
        }
    }

    @Test("Selections survive restart")
    func selectionsSurviveRestart() async throws {
        try await withTestEnvironment { store, _, resolver, session in
            let engine1 = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            await engine1.setCredentialSelection(.source("native.codex", accountID: "saved-acc"), for: .codex)

            let engine2 = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            let selections = await engine2.credentialSelections()
            #expect(selections[.codex] == .source("native.codex", accountID: "saved-acc"))
        }
    }

    @Test("Rate limit 429 restricts fallback strictly to rate-limited identity cache")
    func rateLimit429RestrictsToRateLimitedIdentityCacheOnly() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refB = CredentialReference(sourceID: "omp.codex", accountID: "user-b")
            let cachedB = ProviderUsageSnapshot(
                provider: .codex,
                planName: "Pro",
                fetchedAt: self.fixedDate.addingTimeInterval(-50),
                metrics: [LimitMetric(id: "rate", label: "Rate", usedPercentage: 40, remainingPercentage: 60)],
                isActive: true,
                provenance: UsageProvenance(
                    sourceID: "omp.codex",
                    sourceLabel: "Codex",
                    reference: refB,
                    origin: .live,
                    originalFetchedAt: self.fixedDate.addingTimeInterval(-50)
                )
            )
            try store.saveSnapshot(cachedB)

            let jwtA = makeJWT(now: now + 500, accountID: "user-a")
            let jwtB = makeJWT(now: now, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            StubTransport.setHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                return (response, Data())
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })

            do {
                _ = try await engine.refresh(provider: .codex)
                Issue.record("429 on candidate A must not fall back to candidate B's cache")
            } catch let error as ProviderClientError {
                if case .rateLimited = error {
                    
                } else {
                    Issue.record("Unexpected error: \(error)")
                }
            }
        }
    }

    @Test("Cooldown on first candidate does not hop to other candidates")
    func cooldownDoesNotHop() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let jwtA = makeJWT(now: now + 500, accountID: "user-a")
            let jwtB = makeJWT(now: now, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            let requestCount = RequestCount()
            StubTransport.setHandler { request in
                await requestCount.increment()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: [:]
                )!
                return (response, Data())
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })

            do {
                _ = try await engine.refresh(provider: .codex)
            } catch {
                
            }

            #expect(await requestCount.count() == 1)

            await requestCount.reset()
            do {
                _ = try await engine.refresh(provider: .codex)
            } catch {
                #expect(await requestCount.count() == 0)
            }
        }
    }

    @Test("Stable A cooldown is retained when switching B then back to A")
    func stableAToBToACooldownRetained() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refB = CredentialReference(sourceID: "omp.codex", accountID: "user-b")
            let jwtA = makeJWT(now: now + 500, accountID: "user-a")
            let jwtB = makeJWT(now: now, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            StubTransport.setHandler { request in
                let authHeader = request.allHTTPHeaderFields?["Authorization"] ?? ""
                if authHeader.contains(jwtA) {
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: [:]
                    )!
                    return (response, Data())
                }
                let json = """
                {
                  "plan_type": "ChatGPT Plus / Codex",
                  "credits_remaining": 0.0,
                  "rate_limit": [
                    {
                      "window": "primary",
                      "used_percentage": 20.0,
                      "remaining_percentage": 80.0,
                      "reset_time": 1791320400
                    }
                  ]
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })

            await engine.setCredentialSelection(.source("native.codex", accountID: "user-a"), for: .codex)
            do {
                _ = try await engine.refresh(provider: .codex)
            } catch {
                
            }

            await engine.setCredentialSelection(.source("omp.codex", accountID: "user-b"), for: .codex)
            let resultB = try await engine.refresh(provider: .codex)
            #expect(resultB.provenance?.reference == refB)

            await engine.setCredentialSelection(.source("native.codex", accountID: "user-a"), for: .codex)
            do {
                _ = try await engine.refresh(provider: .codex)
                Issue.record("Candidate A must still be in cooldown")
            } catch let error as ProviderClientError {
                if case .rateLimited = error {
                    
                } else {
                    Issue.record("Unexpected error: \(error)")
                }
            }
        }
    }

    private func withTestEnvironment<T>(
        _ body: (AppGroupStore, URL, CredentialResolver, URLSession) async throws -> T
    ) async throws -> T {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            StubTransport.setHandler(nil)
        }

        let store = AppGroupStore(customDirectoryURL: tempDir)
        let resolver = CredentialResolver(
            home: tempDir,
            environment: [:],
            clock: { self.fixedDate }
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTransport.self]
        let session = URLSession(configuration: config)

        return try await body(store, tempDir, resolver, session)
    }

    private func makeJWT(now: TimeInterval, accountID: String) -> String {
        let header = "eyJhbGciOiJub25lIn0"
        let claims: [String: Any] = ["exp": now + 3600, "account_id": accountID]
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "\(header).\(payload).signature"
    }

    private func writeCodexAuth(home: URL, token: String, accountID: String? = nil) throws {
        let fileURL = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var tokens: [String: Any] = ["access_token": token]
        if let accountID {
            tokens["account_id"] = accountID
        }
        let dict = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func writeClaudeCredentials(home: URL, token: String) throws {
        let fileURL = home.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dict = ["claudeAiOauth": ["accessToken": token]]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func writeOMPDB(home: URL, token: String, accountID: String) throws {
        let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE IF NOT EXISTS auth_credentials (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            disabled_cause TEXT,
            data TEXT NOT NULL
        );
        INSERT INTO auth_credentials (id, provider, disabled_cause, data)
        VALUES (1, 'openai-codex', NULL, '{"access":"\(token)","accountId":"\(accountID)"}');
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

private final class StubTransport: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentHandler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        currentHandler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            let handler = Self.lock.withLock { Self.currentHandler }

            guard let handler else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }

            do {
                let (response, data) = try await handler(self.request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private actor RequestCount {
    private var value = 0

    func increment() { value += 1 }
    func count() -> Int { value }
    func reset() { value = 0 }
}
