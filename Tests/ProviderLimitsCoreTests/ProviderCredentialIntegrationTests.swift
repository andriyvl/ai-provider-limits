import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import ProviderLimitsCore

@Suite("Provider Credential Integration Tests")
struct ProviderCredentialIntegrationTests {
    private let fixedClockDate = Date(timeIntervalSince1970: 1791316800)

    @Test("Claude sends exact token and sets live provenance")
    func testClaudeExactTokenAndProvenance() async throws {
        let host = "claude-token-test.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let secretToken = "claude-live-secret-token"
        IntegrationTestURLProtocol.register(host: host) { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secretToken)")
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")

            let responseBody = Data("""
            {
                "five_hour": {"utilization": 25.0, "resets_at": "2026-10-07T12:00:00Z"},
                "seven_day": {"utilization": 50.0, "resets_at": "2026-10-07T12:00:00Z"}
            }
            """.utf8)
            return (200, ["Content-Type": "application/json"], responseBody)
        }

        try await withTemporaryHome { home in
            try writeClaudeCredentials(home: home, token: secretToken, subscriptionType: "pro")
            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = ClaudeProvider(
                resolver: resolver,
                session: session,
                endpoint: URL(string: "https://\(host)/api/oauth/usage")!
            )

            let snapshot = try await provider.fetchUsage()
            #expect(snapshot.provider == .claude)
            #expect(snapshot.isActive)
            #expect(snapshot.planName == "Pro")
            #expect(snapshot.metrics.count == 2)
            #expect(snapshot.provenance?.sourceID == "native.claude-credentials")
            #expect(snapshot.provenance?.origin == .live)
            #expect(snapshot.provenance?.accountLabel == nil)

            let recorded = IntegrationTestURLProtocol.recordedRequests(for: host)
            #expect(recorded.map { $0.url?.lastPathComponent } == ["usage", "profile"])

            #expect(!snapshot.planName.contains(secretToken))
            #expect(!(snapshot.provenance?.sourceLabel.contains(secretToken) ?? false))
        }
    }

    @Test("Cursor pairs exact token with user ID in query and cookie across parallel requests")
    func testCursorExactTokenUserPairingAndParallelRequests() async throws {
        let host = "cursor-token-test.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let secretToken = "cursor-tok-secret"
        let userId = "user_abc_123"

        IntegrationTestURLProtocol.register(host: host) { request in
            let path = request.url?.path ?? ""
            if path == "/api/usage-summary" {
                let query = request.url?.query ?? ""
                #expect(query == "user=\(userId)")
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                #expect(cookie == "WorkosCursorSessionToken=\(userId)%3A%3A\(secretToken)")
                let body = Data("""
                {
                    "individualUsage": {
                        "plan": {
                            "autoPercentUsed": 30.0,
                            "apiPercentUsed": 60.0
                        }
                    },
                    "billingCycleEnd": "2026-11-01T00:00:00Z"
                }
                """.utf8)
                return (200, ["Content-Type": "application/json"], body)
            } else if path == "/aiserver.v1.DashboardService/GetCreditGrantsBalance" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secretToken)")
                let body = Data("""
                {
                    "hasCreditGrants": true,
                    "creditBalanceCents": 1550
                }
                """.utf8)
                return (200, ["Content-Type": "application/json"], body)
            } else if path == "/aiserver.v1.DashboardService/GetSandUsageStatus" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secretToken)")
                let body = Data("""
                {
                    "usagePercent": 10.0,
                    "nextResetTimestampUtc": "2026-10-15T00:00:00Z"
                }
                """.utf8)
                return (200, ["Content-Type": "application/json"], body)
            } else {
                return (404, [:], Data())
            }
        }

        try await withTemporaryHome { home in
            try createCursorDB(home: home, accessToken: secretToken, userId: userId, membershipType: "pro")
            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = CursorProvider(
                resolver: resolver,
                session: session,
                summaryBaseURL: URL(string: "https://\(host)/api/usage-summary")!,
                creditGrantsURL: URL(string: "https://\(host)/aiserver.v1.DashboardService/GetCreditGrantsBalance")!,
                sandUsageURL: URL(string: "https://\(host)/aiserver.v1.DashboardService/GetSandUsageStatus")!
            )

            let snapshot = try await provider.fetchUsage()
            #expect(snapshot.provider == .cursor)
            #expect(snapshot.isActive)
            #expect(snapshot.creditsRemaining == 15.5)
            #expect(snapshot.metrics.count == 3)
            #expect(snapshot.provenance?.sourceID == "native.cursor-state")
            #expect(snapshot.provenance?.origin == .live)
            #expect(snapshot.provenance?.reference?.accountID == userId)
            #expect(snapshot.provenance?.accountLabel == userId)

            let recorded = IntegrationTestURLProtocol.recordedRequests(for: host)
            #expect(recorded.count == 3)

            #expect(!snapshot.planName.contains(secretToken))
            #expect(!(snapshot.provenance?.sourceLabel.contains(secretToken) ?? false))
        }
    }

    @Test("Cursor safely encodes user ID without user fallback")
    func testCursorSafeUserEncodingNoUserFallback() async throws {
        let host = "cursor-encode-test.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let secretToken = "cursor-tok-safe"
        let complexUserId = "user|special+id:name@org"

        IntegrationTestURLProtocol.register(host: host) { request in
            let path = request.url?.path ?? ""
            if path == "/api/usage-summary" {
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                let userParam = components?.queryItems?.first(where: { $0.name == "user" })?.value
                #expect(userParam == complexUserId)

                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                #expect(!cookie.contains("=user%3A%3A"))
                #expect(!cookie.contains("=user::"))
                #expect(cookie.contains("%3A%3A\(secretToken)"))
                #expect(!cookie.contains("|"))
                #expect(!cookie.contains("@"))

                let body = Data("""
                {
                    "individualUsage": {
                        "plan": {"autoPercentUsed": 10.0}
                    }
                }
                """.utf8)
                return (200, ["Content-Type": "application/json"], body)
            }
            return (200, ["Content-Type": "application/json"], Data("{}".utf8))
        }

        try await withTemporaryHome { home in
            try createCursorDB(home: home, accessToken: secretToken, userId: complexUserId)
            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = CursorProvider(
                resolver: resolver,
                session: session,
                summaryBaseURL: URL(string: "https://\(host)/api/usage-summary")!,
                creditGrantsURL: URL(string: "https://\(host)/credits")!,
                sandUsageURL: URL(string: "https://\(host)/sand")!
            )

            let snapshot = try await provider.fetchUsage()
            #expect(snapshot.isActive)
            #expect(snapshot.provenance?.reference?.accountID == complexUserId)
        }
    }

    @Test("OpenRouter sends exact token and sets live provenance")
    func testOpenRouterExactTokenAndProvenance() async throws {
        let host = "openrouter-token-test.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let secretKey = "sk-or-v1-super-secret"
        IntegrationTestURLProtocol.register(host: host) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secretKey)")
            let path = request.url?.path ?? ""
            if path == "/api/v1/credits" {
                let body = Data("""
                {"data":{"total_credits":50.0,"total_usage":10.0}}
                """.utf8)
                return (200, ["Content-Type": "application/json"], body)
            } else if path == "/api/v1/key" {
                let body = Data("""
                {"data":{"limit":20.0,"limit_remaining":15.0,"usage_daily":2.5,"limit_reset":"monthly"}}
                """.utf8)
                return (200, ["Content-Type": "application/json"], body)
            }
            return (404, [:], Data())
        }

        try await withTemporaryHome { home in
            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": secretKey],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = OpenRouterProvider(
                resolver: resolver,
                session: session,
                creditsEndpoint: URL(string: "https://\(host)/api/v1/credits")!
            )

            let snapshot = try await provider.fetchUsage()
            #expect(snapshot.provider == .openRouter)
            #expect(snapshot.isActive)
            #expect(snapshot.creditsRemaining == 40.0)
            #expect(snapshot.dailySpend == 2.5)
            #expect(snapshot.metrics.count == 2)
            #expect(snapshot.provenance?.sourceID == "process.openrouter-key")
            #expect(snapshot.provenance?.origin == .live)
            #expect(snapshot.provenance?.reference == nil)

            let recorded = IntegrationTestURLProtocol.recordedRequests(for: host)
            #expect(recorded.count == 2)

            #expect(!snapshot.planName.contains(secretKey))
            #expect(!(snapshot.provenance?.sourceLabel.contains(secretKey) ?? false))
        }
    }

    @Test("OpenRouter survives key-stats endpoint failure and returns balance")
    func testOpenRouterOptionalKeyFailureBalanceSurvives() async throws {
        let host = "openrouter-opt-key.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let secretKey = "sk-or-balance-only"
        IntegrationTestURLProtocol.register(host: host) { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/credits" {
                let body = Data("""
                {"data":{"total_credits":100.0,"total_usage":30.0}}
                """.utf8)
                return (200, ["Content-Type": "application/json"], body)
            } else if path == "/api/v1/key" {
                return (500, ["Content-Type": "application/json"], Data("{\"error\":\"internal\"}".utf8))
            }
            return (404, [:], Data())
        }

        try await withTemporaryHome { home in
            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": secretKey],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = OpenRouterProvider(
                resolver: resolver,
                session: session,
                creditsEndpoint: URL(string: "https://\(host)/api/v1/credits")!
            )

            let snapshot = try await provider.fetchUsage()
            #expect(snapshot.isActive)
            #expect(snapshot.creditsRemaining == 70.0)
            #expect(snapshot.dailySpend == nil)
            #expect(snapshot.metrics.count == 1)
            #expect(snapshot.metrics[0].id == "openrouter_credits")
            #expect(snapshot.provenance?.sourceID == "process.openrouter-key")
        }
    }

    @Test("Pinned source selects only pinned credentials without cross-source fallback")
    func testPinnedSourceNoExternalCredential() async throws {
        let host = "openrouter-pin.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let envKey = "sk-or-env"
        let ompKey = "sk-or-omp"

        IntegrationTestURLProtocol.register(host: host) { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let path = request.url?.path ?? ""
            if path == "/api/v1/credits" {
                if auth == "Bearer \(ompKey)" {
                    let body = Data("""
                    {"data":{"total_credits":200.0,"total_usage":50.0}}
                    """.utf8)
                    return (200, ["Content-Type": "application/json"], body)
                }
            }
            return (401, [:], Data())
        }

        try await withTemporaryHome { home in
            try createOMPDB(home: home, credentials: [
                (1, "openrouter", nil, ["key": ompKey])
            ])
            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": envKey],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = OpenRouterProvider(
                resolver: resolver,
                session: session,
                creditsEndpoint: URL(string: "https://\(host)/api/v1/credits")!
            )

            let snapshot = try await provider.fetchUsage(selection: .source("omp.agent-db"))
            #expect(snapshot.isActive)
            #expect(snapshot.creditsRemaining == 150.0)
            #expect(snapshot.provenance?.sourceID == "omp.agent-db")

            let recorded = IntegrationTestURLProtocol.recordedRequests(for: host)
            for req in recorded {
                #expect(req.value(forHTTPHeaderField: "Authorization") != "Bearer \(envKey)")
            }

            let missingPinSnapshot = try await provider.fetchUsage(selection: .source("nonexistent-source"))
            #expect(!missingPinSnapshot.isActive)
            #expect(missingPinSnapshot.metrics.isEmpty)
        }
    }

    @Test("Expired OMP Antigravity login is renewed in memory and the store stays unchanged")
    func testExpiredAntigravityRenewsInMemory() async throws {
        let tokenHost = "oauth2.googleapis.com"
        let quotaHost = "daily-cloudcode-pa.googleapis.com"
        IntegrationTestURLProtocol.reset(host: tokenHost)
        IntegrationTestURLProtocol.reset(host: quotaHost)
        defer {
            IntegrationTestURLProtocol.reset(host: tokenHost)
            IntegrationTestURLProtocol.reset(host: quotaHost)
        }

        let refreshToken = "1//refresh-\(UUID().uuidString)+x"
        IntegrationTestURLProtocol.register(host: tokenHost) { _ in
            (200, ["Content-Type": "application/json"], Data(#"{"access_token":"renewed-access","expires_in":3599}"#.utf8))
        }
        IntegrationTestURLProtocol.register(host: quotaHost) { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-access" else {
                return (401, [:], Data())
            }
            let body = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini_weekly","remainingFraction":0.4}]}]}"#
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }

        try await withTemporaryHome { home in
            let expiredMs = (fixedClockDate.timeIntervalSince1970 - 60) * 1000
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", nil, [
                    "access": "stale-access", "refresh": refreshToken, "expires": expiredMs,
                    "projectId": "proj", "email": "fixture@example.invalid"
                ]),
                (2, "google-antigravity", nil, [
                    "access": "dead-access", "expires": expiredMs, "projectId": "proj-2", "email": "other@example.invalid"
                ])
            ])
            let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
            let storeBefore = try Data(contentsOf: dbURL)
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })

            // Without omp's OAuth client file there is nothing to renew with: the login stays expired.
            let unrenewable = await resolver.resolve(provider: .antigravity)
            #expect(unrenewable.candidates.isEmpty)

            let clientFile = home.appendingPathComponent(
                ".bun/install/global/node_modules/@oh-my-pi/pi-ai/src/registry/oauth/google-antigravity.ts"
            )
            try FileManager.default.createDirectory(at: clientFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encode = { (value: String) in Data(value.utf8).base64EncodedString() }
            try """
            const CLIENT_ID = decode(
            \t"\(encode("synthetic-client.apps.example.invalid"))",
            );
            const CLIENT_SECRET = decode("\(encode("synthetic-secret"))");
            """.write(to: clientFile, atomically: true, encoding: .utf8)

            let provider = AntigravityProvider(resolver: resolver, session: IntegrationTestURLProtocol.makeSession())
            let snapshot = try await provider.fetchUsage()
            #expect(snapshot.isActive)
            #expect(snapshot.metrics.first?.remainingPercentage == 40.0)
            #expect(snapshot.provenance?.accountLabel == "fixture@example.invalid (proj)")

            let tokenRequest = try #require(IntegrationTestURLProtocol.recordedRequests(for: tokenHost).first)
            let bodyStream = try #require(tokenRequest.httpBodyStream)
            bodyStream.open()
            defer { bodyStream.close() }
            var bodyBytes = [UInt8](repeating: 0, count: 4096)
            let bodyLength = bodyStream.read(&bodyBytes, maxLength: bodyBytes.count)
            let form = String(decoding: bodyBytes.prefix(max(0, bodyLength)), as: UTF8.self)
            #expect(form.contains("grant_type=refresh_token"))
            #expect(form.contains("client_id=synthetic-client.apps.example.invalid"))
            #expect(form.contains("client_secret=synthetic-secret"))
            #expect(form.contains("refresh_token=\(refreshToken.replacingOccurrences(of: "+", with: "%2B"))"))
            #expect(try Data(contentsOf: dbURL) == storeBefore)

            let discovery = await resolver.discover(provider: .antigravity)
            let omp = try #require(discovery.sources.first { $0.id == "omp.agent-db" })
            #expect(omp.accounts.map(\.status).sorted { $0.rawValue < $1.rawValue } == [.availableLocally, .expired])
        }
    }

    @Test("Missing credentials make zero outgoing network requests")
    func testMissingCredentialsNoOutgoingTraffic() async throws {
        let host = "missing-creds.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        IntegrationTestURLProtocol.register(host: host) { _ in
            (500, [:], Data())
        }

        try await withTemporaryHome { home in
            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()

            let claudeProvider = ClaudeProvider(
                resolver: resolver,
                session: session,
                endpoint: URL(string: "https://\(host)/claude")!
            )
            let claudeSnapshot = try await claudeProvider.fetchUsage()
            #expect(!claudeSnapshot.isActive)
            #expect(claudeSnapshot.metrics.isEmpty)

            let cursorProvider = CursorProvider(
                resolver: resolver,
                session: session,
                summaryBaseURL: URL(string: "https://\(host)/cursor/summary")!,
                creditGrantsURL: URL(string: "https://\(host)/cursor/credits")!,
                sandUsageURL: URL(string: "https://\(host)/cursor/sand")!
            )
            let cursorSnapshot = try await cursorProvider.fetchUsage()
            #expect(!cursorSnapshot.isActive)
            #expect(cursorSnapshot.metrics.isEmpty)

            let openRouterProvider = OpenRouterProvider(
                resolver: resolver,
                session: session,
                creditsEndpoint: URL(string: "https://\(host)/openrouter/credits")!
            )
            let openRouterSnapshot = try await openRouterProvider.fetchUsage()
            #expect(!openRouterSnapshot.isActive)
            #expect(openRouterSnapshot.metrics.isEmpty)

            let recorded = IntegrationTestURLProtocol.recordedRequests(for: host)
            #expect(recorded.isEmpty)
        }
    }

    @Test("Rate limited request halts immediately without candidate hopping")
    func testRateLimitNoHopping() async throws {
        let host = "rate-limit-test.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let envKey = "sk-or-rate-limited"
        let ompKey = "sk-or-secondary"

        IntegrationTestURLProtocol.register(host: host) { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if auth == "Bearer \(envKey)" {
                return (429, ["Content-Type": "application/json"], Data("{\"error\":\"rate_limited\"}".utf8))
            }
            return (200, ["Content-Type": "application/json"], Data("{\"data\":{\"total_credits\":10.0,\"total_usage\":1.0}}".utf8))
        }

        try await withTemporaryHome { home in
            try createOMPDB(home: home, credentials: [
                (1, "openrouter", nil, ["key": ompKey])
            ])
            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": envKey],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = OpenRouterProvider(
                resolver: resolver,
                session: session,
                creditsEndpoint: URL(string: "https://\(host)/api/v1/credits")!
            )

            await #expect(throws: CredentialRequestFailure.self) {
                try await provider.fetchUsage()
            }

            let recorded = IntegrationTestURLProtocol.recordedRequests(for: host)
            #expect(recorded.count == 1)
            #expect(recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(envKey)")
        }
    }

    @Test("Errors and failure descriptions contain no secrets")
    func testNoSecretOrRawErrorOutputs() async throws {
        let host = "error-safety.local"
        IntegrationTestURLProtocol.reset(host: host)
        defer { IntegrationTestURLProtocol.reset(host: host) }

        let secretToken = "super-secret-claude-token-12345"
        IntegrationTestURLProtocol.register(host: host) { _ in
            (500, ["Content-Type": "application/json"], Data("{\"error\":\"raw server explosion\"}".utf8))
        }

        try await withTemporaryHome { home in
            try writeClaudeCredentials(home: home, token: secretToken)
            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )
            let session = IntegrationTestURLProtocol.makeSession()
            let provider = ClaudeProvider(
                resolver: resolver,
                session: session,
                endpoint: URL(string: "https://\(host)/usage")!
            )

            do {
                _ = try await provider.fetchUsage()
                Issue.record("Expected failure")
            } catch {
                let description = "\(error)"
                #expect(!description.contains(secretToken))
                #expect(!description.contains("raw server explosion"))
            }
        }
    }

    private func withTemporaryHome<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderCredentialIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        return try await body(url)
    }

    private func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeClaudeCredentials(
        home: URL,
        token: String,
        subscriptionType: String? = nil
    ) throws {
        let fileURL = home.appendingPathComponent(".claude/.credentials.json")
        try createDirectory(at: fileURL.deletingLastPathComponent())
        var oauth: [String: Any] = ["accessToken": token]
        if let subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        let dict = ["claudeAiOauth": oauth]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func createCursorDB(
        home: URL,
        accessToken: String,
        userId: String,
        membershipType: String? = nil
    ) throws {
        let dbURL = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try createDirectory(at: dbURL.deletingLastPathComponent())
        var sql = """
        CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', '\(accessToken)');
        INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/stripeMembershipAuthId', '\(userId)');
        """
        if let membershipType {
            sql += "\nINSERT INTO ItemTable (key, value) VALUES ('cursorAuth/stripeMembershipType', '\(membershipType)');"
        }
        try executeSQL(sql, at: dbURL)
    }

    private func createOMPDB(
        home: URL,
        credentials: [(Int64, String, String?, [String: Any])]
    ) throws {
        let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
        try createDirectory(at: dbURL.deletingLastPathComponent())
        var sql = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY,
            provider TEXT NOT NULL,
            disabled_cause TEXT,
            data TEXT NOT NULL
        );
        """
        for (id, provider, disabledCause, data) in credentials {
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let jsonString = String(data: jsonData, encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
            let disabled = disabledCause.map { "'\($0)'" } ?? "NULL"
            sql += """
            \nINSERT INTO auth_credentials (id, provider, disabled_cause, data)
            VALUES (\(id), '\(provider)', \(disabled), '\(jsonString)');
            """
        }
        try executeSQL(sql, at: dbURL)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2)
        }
        #endif
    }
}

private final class IntegrationTestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
        requests[host] = []
    }

    static func reset(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
        requests.removeValue(forKey: host)
    }

    static func recordedRequests(for host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests[host] ?? []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntegrationTestURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let handler: Handler?
        Self.lock.lock()
        handler = Self.handlers[host]
        if handler != nil {
            Self.requests[host, default: []].append(request)
        }
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let (statusCode, headerFields, data) = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
