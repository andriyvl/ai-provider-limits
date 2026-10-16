import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import ProviderLimitsCore

@Suite("Native Credential Sources Tests")
struct NativeCredentialSourcesTests {
    private let fixedClockDate = Date(timeIntervalSince1970: 1791316800)

    @Test("Native Antigravity IDE discovers valid credentials with unknown identity")
    func nativeAntigravityValidCredentials() async throws {
        try await withTemporaryHome { home in
            let futureExpiry: UInt64 = 4102444800
            let topicB64 = makeNativeIDETopic(
                accessToken: "synthetic-native-ide-access",
                expirySeconds: futureExpiry,
                isGCPTOS: true
            )
            try createAntigravityIDEDB(home: home, topicBase64: topicB64)

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let resolution = await resolver.resolve(provider: .antigravity)
            #expect(resolution.discovery.sources.count == 2)

            let nativeSource = resolution.discovery.sources[0]
            #expect(nativeSource.id == "native.antigravity-ide")
            #expect(nativeSource.status == .availableLocally)
            #expect(nativeSource.location == "~/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb")
            #expect(nativeSource.accounts.isEmpty)

            #expect(resolution.candidates.count == 1)
            let candidate = resolution.candidates[0]
            #expect(candidate.sourceID == "native.antigravity-ide")
            #expect(candidate.reference == nil)
            #expect(candidate.expiresAt == TimeInterval(futureExpiry))

            guard case let .nativeAntigravity(credentials) = candidate.payload else {
                Issue.record("Expected nativeAntigravity payload")
                return
            }
            #expect(credentials.accessToken == "synthetic-native-ide-access")
            #expect(credentials.expiresAt == TimeInterval(futureExpiry))
            #expect(credentials.isGCPTOS == true)
        }
    }

    @Test("Native Antigravity IDE ignores UserStatus and maintains unknown identity")
    func nativeAntigravityIgnoresUserStatus() async throws {
        try await withTemporaryHome { home in
            let topicB64 = makeNativeIDETopic(
                accessToken: "synthetic-native-ide-access",
                expirySeconds: 4102444800,
                isGCPTOS: false
            )
            let userStatusB64 = "CnEKFXVzZXJTdGF0dXNTZW50aW5lbEtleRJYClRHaHBUZVc1MGFHVjBhV01nY0hKbGRtbHZkWE1nWVdOamIzVnVkRG9mYzNSaGJHVXRZV05qYjNWdWRDMWlRR1Y0WVcxd2JHVXVhVzUyWVd4cFpBPT0QAg=="
            try createAntigravityIDEDB(home: home, topicBase64: topicB64, userStatusBase64: userStatusB64)

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let resolution = await resolver.resolve(provider: .antigravity)
            let nativeSource = resolution.discovery.sources[0]
            #expect(nativeSource.id == "native.antigravity-ide")
            #expect(nativeSource.status == .availableLocally)
            #expect(nativeSource.accounts.isEmpty)

            #expect(resolution.candidates.count == 1)
            let candidate = resolution.candidates[0]
            #expect(candidate.reference == nil)
            guard case let .nativeAntigravity(credentials) = candidate.payload else {
                Issue.record("Expected nativeAntigravity payload")
                return
            }
            #expect(credentials.accessToken == "synthetic-native-ide-access")
        }
    }

    @Test("Native Antigravity IDE handles expiry boundaries")
    func nativeAntigravityExpiryBoundaries() async throws {
        try await withTemporaryHome { home in
            let expiredSeconds = UInt64(fixedClockDate.timeIntervalSince1970 - 10)
            let expiredB64 = makeNativeIDETopic(
                accessToken: "expired-token",
                expirySeconds: expiredSeconds,
                isGCPTOS: false
            )
            try createAntigravityIDEDB(home: home, topicBase64: expiredB64)

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let resolution = await resolver.resolve(provider: .antigravity)
            let nativeSource = resolution.discovery.sources[0]
            #expect(nativeSource.status == .expired)
            #expect(resolution.candidates.isEmpty)
        }
    }

    @Test("Native Antigravity IDE parser rejects wire format anomalies without trapping")
    func nativeAntigravityWireFormatAnomalies() async throws {
        try await withTemporaryHome { home in
            let testCases: [(name: String, data: Data)] = [
                ("overflowing-varint", Data([0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])),
                ("truncated-varint", Data([0x08, 0x80])),
                ("length-beyond-data", Data([0x0A, 0x64, 0x01, 0x02])),
                ("wrong-sentinel", Data(base64Encoded: makeTopicWithSentinel(sentinelKey: "wrongSentinelKey", oauthData: makeOAuthData(token: "tok", expiry: 4000000000)))!),
                ("corrupt-base64-row", Data(base64Encoded: makeTopicWithCorruptRow())!),
                ("timestamp-overflow", Data(base64Encoded: makeTopicWithTimestampOverflow())!),
                ("missing-token", Data(base64Encoded: makeTopicWithMissingToken())!)
            ]

            for testCase in testCases {
                try createAntigravityIDEDB(home: home, rawValue: testCase.data)
                let resolver = CredentialResolver(
                    home: home,
                    environment: [:],
                    clock: { self.fixedClockDate }
                )
                let resolution = await resolver.resolve(provider: .antigravity)
                let nativeSource = resolution.discovery.sources[0]
                #expect(nativeSource.status == .unsupportedFormat, "Test case \(testCase.name) should be unsupportedFormat")
                #expect(resolution.candidates.isEmpty)
            }
        }
    }

    @Test("Pi Codex discovers valid OAuth credentials with account reference")
    func piCodexValidOAuth() async throws {
        try await withTemporaryHome { home in
            let jwt = makeJWT(claims: ["exp": 4102444800])
            let piAuth: [String: Any] = [
                "openai-codex": [
                    "type": "oauth",
                    "access": jwt,
                    "refresh": "pi-codex-refresh",
                    "expires": 4102444800000,
                    "accountId": "pi-codex-workspace-a"
                ]
            ]
            try writePiAuth(home: home, json: piAuth)

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let resolution = await resolver.resolve(provider: .codex)
            let piSource = resolution.discovery.sources.first { $0.id == "pi.auth-json" }
            #expect(piSource != nil)
            #expect(piSource?.status == .availableLocally)
            #expect(piSource?.location == "~/.pi/agent/auth.json")
            #expect(piSource?.accounts.count == 1)
            #expect(piSource?.accounts[0].label == "pi-codex-workspace-a")

            let piCandidate = resolution.candidates.first { $0.sourceID == "pi.auth-json" }
            #expect(piCandidate != nil)
            #expect(piCandidate?.reference?.accountID == "pi-codex-workspace-a")
            #expect(piCandidate?.expiresAt == 4102444800)

            guard case let .codex(creds) = piCandidate?.payload else {
                Issue.record("Expected codex payload")
                return
            }
            #expect(creds.accessToken == jwt)
            #expect(creds.accountId == "pi-codex-workspace-a")
        }
    }

    @Test("Pi Claude discovers valid OAuth credentials with unknown identity")
    func piClaudeValidOAuth() async throws {
        try await withTemporaryHome { home in
            let piAuth: [String: Any] = [
                "anthropic": [
                    "type": "oauth",
                    "access": "pi-claude-access-token",
                    "refresh": "pi-claude-refresh",
                    "expires": 4102444800000
                ]
            ]
            try writePiAuth(home: home, json: piAuth)

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let resolution = await resolver.resolve(provider: .claude)
            let piSource = resolution.discovery.sources.first { $0.id == "pi.auth-json" }
            #expect(piSource != nil)
            #expect(piSource?.status == .availableLocally)
            #expect(piSource?.accounts.isEmpty == true)

            let candidate = resolution.candidates.first { $0.sourceID == "pi.auth-json" }
            #expect(candidate != nil)
            #expect(candidate?.reference == nil)
            guard case let .claude(creds) = candidate?.payload else {
                Issue.record("Expected claude payload")
                return
            }
            #expect(creds.accessToken == "pi-claude-access-token")
        }
    }

    @Test("Pi OpenRouter accepts literal keys and official OAuth empty refresh sentinel")
    func piOpenRouterSupportedFormats() async throws {
        try await withTemporaryHome { home in
            let literalAuth: [String: Any] = [
                "openrouter": [
                    "type": "api_key",
                    "key": "sk-or-v1-synthetic-not-a-real-key"
                ]
            ]
            try writePiAuth(home: home, json: literalAuth)

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let res1 = await resolver.resolve(provider: .openRouter)
            let source1 = res1.discovery.sources.first { $0.id == "pi.auth-json" }
            #expect(source1?.status == .availableLocally)
            let cand1 = res1.candidates.first { $0.sourceID == "pi.auth-json" }
            #expect(cand1?.reference == nil)
            #expect(cand1?.expiresAt == nil)
            guard case let .openRouter(key1) = cand1?.payload else {
                Issue.record("Expected openRouter payload")
                return
            }
            #expect(key1 == "sk-or-v1-synthetic-not-a-real-key")

            let oauthAuth: [String: Any] = [
                "openrouter": [
                    "type": "oauth",
                    "access": "sk-or-v1-synthetic-login-key",
                    "refresh": "",
                    "expires": 9007199254740991
                ]
            ]
            try writePiAuth(home: home, json: oauthAuth)

            let res2 = await resolver.resolve(provider: .openRouter)
            let source2 = res2.discovery.sources.first { $0.id == "pi.auth-json" }
            #expect(source2?.status == .availableLocally)
            let cand2 = res2.candidates.first { $0.sourceID == "pi.auth-json" }
            #expect(cand2?.reference == nil)
            #expect(cand2?.expiresAt == nil)
            guard case let .openRouter(key2) = cand2?.payload else {
                Issue.record("Expected openRouter payload")
                return
            }
            #expect(key2 == "sk-or-v1-synthetic-login-key")
        }
    }

    @Test("Pi OpenRouter rejects command and environment expressions")
    func piOpenRouterRejectsExpressions() async throws {
        try await withTemporaryHome { home in
            let rejectedKeys = [
                "!echo synthetic",
                "OPENROUTER_API_KEY",
                "$OPENROUTER_API_KEY",
                "${OPENROUTER_API_KEY}"
            ]

            for key in rejectedKeys {
                let auth: [String: Any] = [
                    "openrouter": [
                        "type": "api_key",
                        "key": key
                    ]
                ]
                try writePiAuth(home: home, json: auth)

                let resolver = CredentialResolver(
                    home: home,
                    environment: [:],
                    clock: { self.fixedClockDate }
                )

                let res = await resolver.resolve(provider: .openRouter)
                let source = res.discovery.sources.first { $0.id == "pi.auth-json" }
                #expect(source?.status == .unsupportedFormat, "Key \(key) should be rejected")
                #expect(res.candidates.filter { $0.sourceID == "pi.auth-json" }.isEmpty)
            }
        }
    }

    @Test("Pi parses known records independently without masking valid providers")
    func piIndependentRecordParsing() async throws {
        try await withTemporaryHome { home in
            let mixedAuth: [String: Any] = [
                "openai-codex": [
                    "type": "oauth",
                    "access": "synthetic-access",
                    "refresh": "refresh",
                    "expires": 4102444800000,
                    "accountId": "valid-account"
                ],
                "anthropic": [
                    "type": "malformed_type",
                    "broken": 123
                ]
            ]
            try writePiAuth(home: home, json: mixedAuth)

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let codexRes = await resolver.resolve(provider: .codex)
            let codexPi = codexRes.discovery.sources.first { $0.id == "pi.auth-json" }
            #expect(codexPi?.status == .availableLocally)
            #expect(codexRes.candidates.contains { $0.sourceID == "pi.auth-json" })

            let claudeRes = await resolver.resolve(provider: .claude)
            let claudePi = claudeRes.discovery.sources.first { $0.id == "pi.auth-json" }
            #expect(claudePi?.status == .unsupportedFormat)
            #expect(claudeRes.candidates.filter { $0.sourceID == "pi.auth-json" }.isEmpty)
        }
    }

    @Test("Pi location override respects relative paths, tilde, and sanitizes raw home")
    func piLocationOverrides() async throws {
        try await withTemporaryHome { home in
            let envRelative = ["PI_CODING_AGENT_DIR": "custom-agent"]
            let (url1, loc1) = PiCredentialSource.resolveLocation(home: home, environment: envRelative)
            #expect(url1.path == home.appendingPathComponent("custom-agent/auth.json").path)
            #expect(loc1 == "~/custom-agent/auth.json")

            let envTilde = ["PI_CODING_AGENT_DIR": "~/custom-pi"]
            let (url2, loc2) = PiCredentialSource.resolveLocation(home: home, environment: envTilde)
            #expect(url2.path == home.appendingPathComponent("custom-pi/auth.json").path)
            #expect(loc2 == "~/custom-pi/auth.json")

            let envExactTilde = ["PI_CODING_AGENT_DIR": "~"]
            let (url3, loc3) = PiCredentialSource.resolveLocation(home: home, environment: envExactTilde)
            #expect(url3.path == home.appendingPathComponent("auth.json").path)
            #expect(loc3 == "~/auth.json")

            let envOtherUser = ["PI_CODING_AGENT_DIR": "/Users/otheruser/.pi/agent"]
            let (_, loc4) = PiCredentialSource.resolveLocation(home: home, environment: envOtherUser)
            #expect(loc4 == "~/.pi/agent/auth.json")
        }
    }

    @Test("Codex orders candidates by global descending JWT expiry with deterministic ties")
    func codexGlobalJWTOrdering() async throws {
        try await withTemporaryHome { home in
            let nativeJWT = makeJWT(claims: ["exp": 2000])
            try writeCodexAuth(home: home, token: nativeJWT, accountId: "native-acc")

            let piJWT = makeJWT(claims: ["exp": 3000])
            let piAuth: [String: Any] = [
                "openai-codex": [
                    "type": "oauth",
                    "access": piJWT,
                    "refresh": "ref",
                    "expires": 3000000,
                    "accountId": "pi-acc"
                ]
            ]
            try writePiAuth(home: home, json: piAuth)

            let ompJWT = makeJWT(claims: ["exp": 2500])
            try createOMPDB(home: home, credentials: [
                (1, "openai-codex", nil, ["access": ompJWT, "accountId": "omp-acc"])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { Date(timeIntervalSince1970: 1000) }
            )

            let resolution = await resolver.resolve(provider: .codex)
            #expect(resolution.candidates.count == 3)
            #expect(resolution.candidates[0].sourceID == "pi.auth-json")
            #expect(resolution.candidates[1].sourceID == "omp.agent-db")
            #expect(resolution.candidates[2].sourceID == "native.codex-auth")
        }
    }

    @Test("Codex resolves deterministic ties for equal JWT expiry")
    func codexEqualExpiryDeterministicTies() async throws {
        try await withTemporaryHome { home in
            let equalJWT = makeJWT(claims: ["exp": 3000])
            try writeCodexAuth(home: home, token: equalJWT, accountId: "native-acc")

            let piAuth: [String: Any] = [
                "openai-codex": [
                    "type": "oauth",
                    "access": equalJWT,
                    "refresh": "ref",
                    "expires": 3000000,
                    "accountId": "pi-acc"
                ]
            ]
            try writePiAuth(home: home, json: piAuth)

            try createOMPDB(home: home, credentials: [
                (1, "openai-codex", nil, ["access": equalJWT, "accountId": "omp-acc"])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { Date(timeIntervalSince1970: 1000) }
            )

            let resolution = await resolver.resolve(provider: .codex)
            #expect(resolution.candidates.count == 3)
            #expect(resolution.candidates[0].sourceID == "native.codex-auth")
            #expect(resolution.candidates[1].sourceID == "pi.auth-json")
            #expect(resolution.candidates[2].sourceID == "omp.agent-db")
        }
    }

    @Test("Pinning sources and accounts enforces exact matches and preserves unknown identity policy")
    func pinningPolicyVerification() async throws {
        try await withTemporaryHome { home in
            let topicB64 = makeNativeIDETopic(
                accessToken: "native-token",
                expirySeconds: 4102444800,
                isGCPTOS: false
            )
            try createAntigravityIDEDB(home: home, topicBase64: topicB64)
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", nil, ["access": "omp-token", "projectId": "p1"])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let automaticRes = await resolver.resolve(provider: .antigravity, selection: .automatic)
            #expect(automaticRes.candidates.count == 2)
            #expect(automaticRes.candidates[0].sourceID == "native.antigravity-ide")
            #expect(automaticRes.candidates[1].sourceID == "omp.agent-db")

            let sourcePinned = await resolver.resolve(
                provider: .antigravity,
                selection: .source("native.antigravity-ide")
            )
            #expect(sourcePinned.candidates.count == 1)
            #expect(sourcePinned.candidates[0].sourceID == "native.antigravity-ide")

            let accountPinned = await resolver.resolve(
                provider: .antigravity,
                selection: .source("native.antigravity-ide", accountID: "cannot-pin")
            )
            #expect(accountPinned.candidates.isEmpty)
        }
    }

    @Test("Input bytes remain unchanged after discovery and resolution")
    func inputBytesUnchanged() async throws {
        try await withTemporaryHome { home in
            let topicB64 = makeNativeIDETopic(
                accessToken: "native-token",
                expirySeconds: 4102444800,
                isGCPTOS: false
            )
            try createAntigravityIDEDB(home: home, topicBase64: topicB64)

            let piAuth: [String: Any] = [
                "openai-codex": [
                    "type": "oauth",
                    "access": makeJWT(claims: ["exp": 4102444800]),
                    "refresh": "ref",
                    "expires": 4102444800000,
                    "accountId": "acc"
                ]
            ]
            try writePiAuth(home: home, json: piAuth)

            let ideURL = home.appendingPathComponent(
                "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"
            )
            let piURL = home.appendingPathComponent(".pi/agent/auth.json")

            let ideHashBefore = SHA256.hash(data: try Data(contentsOf: ideURL))
            let piHashBefore = SHA256.hash(data: try Data(contentsOf: piURL))

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            _ = await resolver.discover(provider: .antigravity)
            _ = await resolver.resolve(provider: .antigravity)
            _ = await resolver.discover(provider: .codex)
            _ = await resolver.resolve(provider: .codex)

            let ideHashAfter = SHA256.hash(data: try Data(contentsOf: ideURL))
            let piHashAfter = SHA256.hash(data: try Data(contentsOf: piURL))

            #expect(ideHashBefore == ideHashAfter)
            #expect(piHashBefore == piHashAfter)
        }
    }

    private func withTemporaryHome<T>(_ body: (URL) async throws -> T) async throws -> T {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-cred-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        return try await body(tempDir)
    }

    private func createAntigravityIDEDB(
        home: URL,
        topicBase64: String? = nil,
        userStatusBase64: String? = nil,
        rawValue: Data? = nil
    ) throws {
        let dbURL = home.appendingPathComponent(
            "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"
        )
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(db) }

        let createTable = "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);"
        guard sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2)
        }

        if let rawValue {
            var stmt: OpaquePointer?
            let insert = "INSERT INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.oauthToken', ?);"
            guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLite", code: 3)
            }
            defer { sqlite3_finalize(stmt) }
            rawValue.withUnsafeBytes { ptr in
                _ = sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(rawValue.count), nil)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw NSError(domain: "SQLite", code: 4)
            }
        } else if let topicBase64 {
            let insert = "INSERT INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.oauthToken', '\(topicBase64)');"
            guard sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLite", code: 5)
            }
        }

        if let userStatusBase64 {
            let insert = "INSERT INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.userStatus', '\(userStatusBase64)');"
            guard sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLite", code: 6)
            }
        }
    }

    private func writePiAuth(home: URL, json: [String: Any]) throws {
        let fileURL = home.appendingPathComponent(".pi/agent/auth.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try data.write(to: fileURL)
    }

    private func writeCodexAuth(home: URL, token: String, accountId: String?) throws {
        let fileURL = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var tokens: [String: Any] = ["access_token": token]
        if let accountId { tokens["account_id"] = accountId }
        let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
        try data.write(to: fileURL)
    }

    private func createOMPDB(
        home: URL,
        credentials: [(Int64, String, String?, [String: Any])]
    ) throws {
        let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(db) }

        var sql = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            credential_type TEXT NOT NULL,
            data TEXT NOT NULL,
            disabled_cause TEXT,
            identity_key TEXT,
            created_at INTEGER,
            updated_at INTEGER
        );
        CREATE TABLE cache (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            expires_at INTEGER NOT NULL
        );
        """
        for (id, provider, disabledCause, data) in credentials {
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let jsonString = String(data: jsonData, encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
            let disabled = disabledCause.map { "'\($0)'" } ?? "NULL"
            let credentialType = provider == "openrouter" ? "api_key" : "oauth"
            sql += """
            \nINSERT INTO auth_credentials (id, provider, credential_type, data, disabled_cause)
            VALUES (\(id), '\(provider)', '\(credentialType)', '\(jsonString)', \(disabled));
            """
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2)
        }
    }

    private func makeJWT(claims: [String: Any]) -> String {
        let header = "eyJhbGciOiJub25lIn0"
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "\(header).\(payload).signature"
    }

    private func encodeVarint(_ val: UInt64) -> Data {
        var value = val
        var bytes = [UInt8]()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return Data(bytes)
    }

    private func encodeField(number: Int, wireType: Int, data: Data) -> Data {
        let tag = UInt64((number << 3) | wireType)
        var res = encodeVarint(tag)
        if wireType == 0 {
            res.append(data)
        } else if wireType == 2 {
            res.append(encodeVarint(UInt64(data.count)))
            res.append(data)
        }
        return res
    }

    private func makeOAuthData(token: String, expiry: UInt64, isGCPTOS: Bool = false) -> Data {
        var res = Data()
        res.append(encodeField(number: 1, wireType: 2, data: Data(token.utf8)))
        res.append(encodeField(number: 2, wireType: 2, data: Data("Bearer".utf8)))
        res.append(encodeField(number: 3, wireType: 2, data: Data("ref".utf8)))
        let ts = encodeField(number: 1, wireType: 0, data: encodeVarint(expiry))
        res.append(encodeField(number: 4, wireType: 2, data: ts))
        if isGCPTOS {
            res.append(encodeField(number: 6, wireType: 0, data: encodeVarint(1)))
        }
        return res
    }

    private func makeTopicWithSentinel(sentinelKey: String, oauthData: Data) -> String {
        let oauthB64 = oauthData.base64EncodedString()
        var row = Data()
        row.append(encodeField(number: 1, wireType: 2, data: Data(oauthB64.utf8)))
        row.append(encodeField(number: 2, wireType: 0, data: encodeVarint(1)))

        var entry = Data()
        entry.append(encodeField(number: 1, wireType: 2, data: Data(sentinelKey.utf8)))
        entry.append(encodeField(number: 2, wireType: 2, data: row))

        let topic = encodeField(number: 1, wireType: 2, data: entry)
        return topic.base64EncodedString()
    }

    private func makeTopicWithCorruptRow() -> String {
        var row = Data()
        row.append(encodeField(number: 1, wireType: 2, data: Data("%%%not-valid-base64%%%".utf8)))
        row.append(encodeField(number: 2, wireType: 0, data: encodeVarint(1)))

        var entry = Data()
        entry.append(encodeField(number: 1, wireType: 2, data: Data("oauthTokenInfoSentinelKey".utf8)))
        entry.append(encodeField(number: 2, wireType: 2, data: row))

        let topic = encodeField(number: 1, wireType: 2, data: entry)
        return topic.base64EncodedString()
    }

    private func makeTopicWithTimestampOverflow() -> String {
        var oauth = Data()
        oauth.append(encodeField(number: 1, wireType: 2, data: Data("token".utf8)))
        let ts = encodeField(number: 1, wireType: 0, data: Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]))
        oauth.append(encodeField(number: 4, wireType: 2, data: ts))
        return makeTopicWithSentinel(sentinelKey: "oauthTokenInfoSentinelKey", oauthData: oauth)
    }

    private func makeTopicWithMissingToken() -> String {
        var oauth = Data()
        let ts = encodeField(number: 1, wireType: 0, data: encodeVarint(4102444800))
        oauth.append(encodeField(number: 4, wireType: 2, data: ts))
        return makeTopicWithSentinel(sentinelKey: "oauthTokenInfoSentinelKey", oauthData: oauth)
    }

    private func makeNativeIDETopic(
        accessToken: String,
        expirySeconds: UInt64,
        isGCPTOS: Bool
    ) -> String {
        let oauthData = makeOAuthData(token: accessToken, expiry: expirySeconds, isGCPTOS: isGCPTOS)
        return makeTopicWithSentinel(sentinelKey: "oauthTokenInfoSentinelKey", oauthData: oauthData)
    }
}
