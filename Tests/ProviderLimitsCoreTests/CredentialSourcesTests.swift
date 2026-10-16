import Foundation
import SQLite3
import Testing
@testable import ProviderLimitsCore

@Suite("Credential Sources Tests")
struct CredentialSourcesTests {
    private let fixedClockDate = Date(timeIntervalSince1970: 1791316800)

    @Test("Missing sources report missing status and zero candidates")
    func missingSourcesReportMissingStatusAndZeroCandidates() async throws {
        try await withTemporaryHome { home in
            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            for provider in ProviderType.allCases {
                let resolution = await resolver.resolve(provider: provider)
                #expect(resolution.candidates.isEmpty)
                for source in resolution.discovery.sources {
                    #expect(source.status == .missing)
                    #expect(source.accounts.isEmpty)
                }
            }
        }
    }

    @Test("Unreadable sources handle denied access and throwing reader")
    func unreadableSourcesHandleDeniedAccessAndThrowingReader() async throws {
        try await withTemporaryHome { home in
            try writeCodexAuth(home: home, token: "token", accountId: "acc")
            try writeClaudeCredentials(home: home, token: "token")
            try createCursorDB(home: home, accessToken: "token", userId: "user-1")
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", nil, ["access": "token", "projectId": "proj"]),
                (2, "openai-codex", nil, ["access": "omp-codex-token", "accountId": "acc-omp"])
            ])

            let deniedAccessResolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate },
                access: { _ in false }
            )

            let deniedCodex = await deniedAccessResolver.resolve(provider: .codex)
            #expect(deniedCodex.discovery.sources[0].status == .unreadable)
            #expect(deniedCodex.discovery.sources[1].status == .unreadable)
            #expect(deniedCodex.candidates.isEmpty)

            let deniedClaude = await deniedAccessResolver.resolve(provider: .claude)
            #expect(deniedClaude.discovery.sources[0].status == .unreadable)
            #expect(deniedClaude.candidates.isEmpty)

            let deniedCursor = await deniedAccessResolver.resolve(provider: .cursor)
            #expect(deniedCursor.discovery.sources[0].status == .unreadable)
            #expect(deniedCursor.discovery.sources[1].status == .unreadable)
            #expect(deniedCursor.candidates.isEmpty)

            let throwingResolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate },
                readFile: { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
            )

            let throwingCodex = await throwingResolver.resolve(provider: .codex)
            #expect(throwingCodex.discovery.sources[0].status == .unreadable)
            #expect(throwingCodex.candidates.count == 1)

            let throwingClaude = await throwingResolver.resolve(provider: .claude)
            #expect(throwingClaude.discovery.sources[0].status == .unreadable)
            #expect(throwingClaude.candidates.isEmpty)
        }
    }

    @Test("Malformed native sources do not hide valid alternatives")
    func malformedNativeSourcesDoNotHideValidAlternatives() async throws {
        try await withTemporaryHome { home in
            let codexURL = home.appendingPathComponent(".codex/auth.json")
            try createDirectory(at: codexURL.deletingLastPathComponent())
            try "corrupted-json-payload".write(to: codexURL, atomically: true, encoding: .utf8)

            try createOMPDB(home: home, credentials: [
                (1, "openai-codex", nil, ["access": "omp-codex-access", "accountId": "acc-omp-1"])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedClockDate }
            )

            let resolution = await resolver.resolve(provider: .codex)
            #expect(resolution.discovery.sources.first { $0.id == "native.codex-auth" }?.status == .unsupportedFormat)
            #expect(resolution.discovery.sources.first { $0.id == "omp.agent-db" }?.status == .availableLocally)
            #expect(resolution.candidates.count == 1)

            let candidate = try #require(resolution.candidates.first)
            #expect(candidate.sourceID == "omp.agent-db")
            if case let .codex(credentials) = candidate.payload {
                #expect(credentials.accessToken == "omp-codex-access")
                #expect(credentials.accountId == "acc-omp-1")
            } else {
                Issue.record("Expected .codex payload")
            }
        }
    }

    @Test("Expired native Claude falls back to live OMP anthropic login")
    func expiredNativeClaudeFallsBackToOMPAnthropic() async throws {
        try await withTemporaryHome { home in
            let nowMs = Int64(fixedClockDate.timeIntervalSince1970 * 1000)
            try writeClaudeCredentials(home: home, token: "native-expired", expiresAt: nowMs - 1)
            try createOMPDB(home: home, credentials: [
                (1, "anthropic", nil, ["access": "omp-claude-old", "expires": nowMs - 1, "accountId": "acc-old"]),
                (2, "anthropic", nil, [
                    "access": "omp-claude-live", "expires": nowMs + 3_600_000,
                    "accountId": "acc-live", "email": "live@example.invalid"
                ])
            ])

            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })
            let resolution = await resolver.resolve(provider: .claude)

            #expect(resolution.discovery.sources.first { $0.id == "native.claude-credentials" }?.status == .expired)
            let omp = try #require(resolution.discovery.sources.first { $0.id == "omp.agent-db" })
            #expect(omp.status == .availableLocally)
            #expect(omp.accounts.map(\.label).sorted() == ["acc-old", "live@example.invalid"])
            #expect(resolution.candidates.count == 1)

            let candidate = try #require(resolution.candidates.first)
            #expect(candidate.sourceID == "omp.agent-db")
            #expect(candidate.reference?.accountID == "acc-live")
            guard case let .claude(credentials) = candidate.payload else {
                Issue.record("Expected .claude payload")
                return
            }
            #expect(credentials.accessToken == "omp-claude-live")
        }
    }

    @Test("Empty environment for OpenRouter falls back to OMP key")
    func emptyEnvironmentForOpenRouter() async throws {
        try await withTemporaryHome { home in
            try createOMPDB(home: home, credentials: [
                (1, "openrouter", nil, ["key": "omp-openrouter-key"])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": "   "],
                clock: { self.fixedClockDate }
            )

            let resolution = await resolver.resolve(provider: .openRouter)
            #expect(resolution.discovery.sources.first { $0.id == "process.openrouter-key" }?.status == .missing)
            #expect(resolution.discovery.sources.first { $0.id == "omp.agent-db" }?.status == .availableLocally)
            #expect(resolution.candidates.count == 1)

            let candidate = try #require(resolution.candidates.first)
            #expect(candidate.sourceID == "omp.agent-db")
            if case let .openRouter(key) = candidate.payload {
                #expect(key == "omp-openrouter-key")
            } else {
                Issue.record("Expected .openRouter payload")
            }
        }
    }

    @Test("Expiry boundary conditions accurately exclude expired tokens")
    func expiryBoundaryConditions() async throws {
        try await withTemporaryHome { home in
            let nowSeconds = self.fixedClockDate.timeIntervalSince1970

            let exactClaude = home.appendingPathComponent("exact")
            try writeClaudeCredentials(home: exactClaude, token: "claude-exact", expiresAt: Int64(nowSeconds * 1000))
            let exactClaudeResolver = CredentialResolver(home: exactClaude, environment: [:], clock: { self.fixedClockDate })
            let exactClaudeRes = await exactClaudeResolver.resolve(provider: .claude)
            #expect(exactClaudeRes.discovery.sources[0].status == .expired)
            #expect(exactClaudeRes.candidates.isEmpty)

            let futureClaude = home.appendingPathComponent("future")
            try writeClaudeCredentials(home: futureClaude, token: "claude-future", expiresAt: Int64((nowSeconds + 1) * 1000))
            let futureClaudeResolver = CredentialResolver(home: futureClaude, environment: [:], clock: { self.fixedClockDate })
            let futureClaudeRes = await futureClaudeResolver.resolve(provider: .claude)
            #expect(futureClaudeRes.discovery.sources[0].status == .availableLocally)
            #expect(futureClaudeRes.candidates.count == 1)

            let pastClaude = home.appendingPathComponent("past")
            try writeClaudeCredentials(home: pastClaude, token: "claude-past", expiresAt: Int64((nowSeconds - 1) * 1000))
            let pastClaudeResolver = CredentialResolver(home: pastClaude, environment: [:], clock: { self.fixedClockDate })
            let pastClaudeRes = await pastClaudeResolver.resolve(provider: .claude)
            #expect(pastClaudeRes.discovery.sources[0].status == .expired)
            #expect(pastClaudeRes.candidates.isEmpty)

            let exactCodex = home.appendingPathComponent("codex-exact")
            let exactJWT = makeJWT(claims: ["exp": nowSeconds])
            try writeCodexAuth(home: exactCodex, token: exactJWT, accountId: "acc-exact")
            let exactCodexResolver = CredentialResolver(home: exactCodex, environment: [:], clock: { self.fixedClockDate })
            let exactCodexRes = await exactCodexResolver.resolve(provider: .codex)
            #expect(exactCodexRes.discovery.sources[0].status == .expired)
            #expect(exactCodexRes.candidates.isEmpty)

            let futureCodex = home.appendingPathComponent("codex-future")
            let futureJWT = makeJWT(claims: ["exp": nowSeconds + 10])
            try writeCodexAuth(home: futureCodex, token: futureJWT, accountId: "acc-future")
            let futureCodexResolver = CredentialResolver(home: futureCodex, environment: [:], clock: { self.fixedClockDate })
            let futureCodexRes = await futureCodexResolver.resolve(provider: .codex)
            #expect(futureCodexRes.discovery.sources[0].status == .availableLocally)
            #expect(futureCodexRes.candidates.count == 1)
        }
    }

    @Test("Disabled records are excluded from candidates but discovered with disabled status")
    func disabledRecordsExcludedFromCandidates() async throws {
        try await withTemporaryHome { home in
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", "revoked", [
                    "access": "disabled-token",
                    "projectId": "disabled-project",
                    "email": "disabled@example.invalid"
                ])
            ])

            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })
            let resolution = await resolver.resolve(provider: .antigravity)

            #expect(resolution.candidates.isEmpty)
            let source = try #require(resolution.discovery.sources.first { $0.id == "omp.agent-db" })
            #expect(source.status == .disabled)
            #expect(source.accounts.count == 1)
            #expect(source.accounts[0].status == .disabled)
            let databaseURL = home.appendingPathComponent(".omp/agent/agent.db")
            try executeSQL("UPDATE auth_credentials SET disabled_cause = '';", at: databaseURL)
            let emptyCause = await resolver.resolve(provider: .antigravity)
            #expect(emptyCause.candidates.isEmpty)
            #expect(emptyCause.discovery.sources.first { $0.id == "omp.agent-db" }?.status == .disabled)
            #expect(source.accounts[0].label == "disabled@example.invalid (disabled-project)")
        }
    }


    @Test("Resolve typed payloads without invoking fetch")
    func resolveTypedPayloadsWithoutInvokingFetch() async throws {
        try await withTemporaryHome { home in
            try writeCodexAuth(home: home, token: "codex-bearer-token", accountId: "codex-acc-id")
            try writeClaudeCredentials(home: home, token: "claude-bearer-token", subscriptionType: "team")
            try createCursorDB(home: home, accessToken: "cursor-bearer-token", userId: "cursor-stripe-id", membershipType: "pro")
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", nil, [
                    "access": "antigravity-bearer-token",
                    "projectId": "antigravity-proj-id",
                    "email": "developer@example.invalid"
                ]),
                (2, "openrouter", nil, [
                    "key": "openrouter-sk-key"
                ])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": "openrouter-env-key"],
                clock: { self.fixedClockDate }
            )

            let antigravityRes = await resolver.resolve(provider: .antigravity)
            let agCandidate = try #require(antigravityRes.candidates.first)
            if case let .antigravity(credentials) = agCandidate.payload {
                #expect(credentials.accessToken == "antigravity-bearer-token")
                #expect(credentials.projectId == "antigravity-proj-id")
                #expect(credentials.email == "developer@example.invalid")
            } else {
                Issue.record("Expected .antigravity payload")
            }

            let codexRes = await resolver.resolve(provider: .codex)
            let codexCandidate = try #require(codexRes.candidates.first)
            if case let .codex(credentials) = codexCandidate.payload {
                #expect(credentials.accessToken == "codex-bearer-token")
                #expect(credentials.accountId == "codex-acc-id")
            } else {
                Issue.record("Expected .codex payload")
            }

            let claudeRes = await resolver.resolve(provider: .claude)
            let claudeCandidate = try #require(claudeRes.candidates.first)
            if case let .claude(credentials) = claudeCandidate.payload {
                #expect(credentials.accessToken == "claude-bearer-token")
                #expect(credentials.subscriptionType == "team")
            } else {
                Issue.record("Expected .claude payload")
            }

            let cursorRes = await resolver.resolve(provider: .cursor)
            let cursorCandidate = try #require(cursorRes.candidates.first)
            if case let .cursor(credentials) = cursorCandidate.payload {
                #expect(credentials.accessToken == "cursor-bearer-token")
                #expect(credentials.userId == "cursor-stripe-id")
                #expect(credentials.membershipType == "pro")
            } else {
                Issue.record("Expected .cursor payload")
            }

            let openRouterRes = await resolver.resolve(provider: .openRouter)
            let orCandidate = try #require(openRouterRes.candidates.first)
            if case let .openRouter(key) = orCandidate.payload {
                #expect(key == "openrouter-env-key")
            } else {
                Issue.record("Expected .openRouter payload")
            }
        }
    }

    @Test("Unknown identities have no stable reference or account descriptor")
    func unknownIdentitiesHaveNoStableReference() async throws {
        try await withTemporaryHome { home in
            try writeClaudeCredentials(home: home, token: "claude-token")
            let cursorJWT = makeJWT(claims: ["sub": "cursor-jwt-sub"])
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", nil, [
                    "access": "ag-token",
                    "projectId": "ag-project"
                ]),
                (2, "cursor", nil, [
                    "access": cursorJWT
                ]),
                (3, "openrouter", nil, [
                    "key": "omp-or-key"
                ])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": "env-or-key"],
                clock: { self.fixedClockDate }
            )

            let claudeRes = await resolver.resolve(provider: .claude)
            let claudeCandidate = try #require(claudeRes.candidates.first)
            #expect(claudeCandidate.reference == nil)
            #expect(claudeRes.discovery.sources[0].accounts.isEmpty)

            let agRes = await resolver.resolve(provider: .antigravity)
            let agCandidate = try #require(agRes.candidates.first)
            #expect(agCandidate.reference == nil)
            #expect(agRes.discovery.sources.first { $0.id == "omp.agent-db" }?.accounts.isEmpty == true)

            let cursorRes = await resolver.resolve(provider: .cursor)
            let ompCursorCandidate = try #require(cursorRes.candidates.first(where: { $0.sourceID == "omp.agent-db" }))
            #expect(ompCursorCandidate.reference == nil)
            #expect(cursorRes.discovery.sources[1].accounts.isEmpty)

            let orRes = await resolver.resolve(provider: .openRouter)
            for candidate in orRes.candidates {
                #expect(candidate.reference == nil)
            }
            #expect(orRes.discovery.sources[0].accounts.isEmpty)
            #expect(orRes.discovery.sources.first { $0.id == "omp.agent-db" }?.accounts.isEmpty == true)
        }
    }

    @Test("Native Cursor requires explicit user ID distinct from access token")
    func nativeCursorRequiresExplicitUserId() async throws {
        try await withTemporaryHome { home in
            let missingUserHome = home.appendingPathComponent("missing-user")
            let dbURL1 = missingUserHome.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            try createDirectory(at: dbURL1.deletingLastPathComponent())
            try executeSQL("""
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', 'sample-token');
            """, at: dbURL1)
            let missingResolver = CredentialResolver(home: missingUserHome, environment: [:], clock: { self.fixedClockDate })
            let missingRes = await missingResolver.resolve(provider: .cursor)
            #expect(missingRes.discovery.sources[0].status == .unsupportedFormat)
            #expect(missingRes.candidates.isEmpty)

            let sameUserHome = home.appendingPathComponent("same-user")
            let dbURL2 = sameUserHome.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            try createDirectory(at: dbURL2.deletingLastPathComponent())
            try executeSQL("""
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', 'identical-token');
            INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/stripeMembershipAuthId', 'identical-token');
            """, at: dbURL2)
            let sameResolver = CredentialResolver(home: sameUserHome, environment: [:], clock: { self.fixedClockDate })
            let sameRes = await sameResolver.resolve(provider: .cursor)
            #expect(sameRes.discovery.sources[0].status == .unsupportedFormat)
            #expect(sameRes.candidates.isEmpty)
        }
    }

    @Test("OMP Cursor missing sub claim is rejected")
    func ompCursorMissingSubRejected() async throws {
        try await withTemporaryHome { home in
            let invalidJWT = makeJWT(claims: ["aud": "cursor"])
            try createOMPDB(home: home, credentials: [
                (1, "cursor", nil, ["access": invalidJWT]),
                (2, "cursor", nil, ["access": "non-jwt-raw-string"])
            ])

            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })
            let res = await resolver.resolve(provider: .cursor)
            let ompCandidates = res.candidates.filter { $0.sourceID == "omp.agent-db" }
            #expect(ompCandidates.isEmpty)
            #expect(res.discovery.sources[1].status == .unsupportedFormat)
        }
    }

    @Test("JWT expiry non numeric claim is rejected as unsupported format")
    func jwtExpiryClaimValidation() async throws {
        try await withTemporaryHome { home in
            let nonNumericCodexHome = home.appendingPathComponent("codex-invalid-exp")
            let malformedCodexJWT = makeJWT(claims: ["exp": "tomorrow"])
            try writeCodexAuth(home: nonNumericCodexHome, token: malformedCodexJWT, accountId: "acc-1")
            let codexResolver = CredentialResolver(home: nonNumericCodexHome, environment: [:], clock: { self.fixedClockDate })
            let codexRes = await codexResolver.resolve(provider: .codex)
            #expect(codexRes.discovery.sources[0].status == .unsupportedFormat)
            #expect(codexRes.candidates.isEmpty)

            let booleanCursorHome = home.appendingPathComponent("cursor-bool-exp")
            let boolExpJWT = makeJWT(claims: ["exp": true, "sub": "user-sub"])
            try createCursorDB(home: booleanCursorHome, accessToken: boolExpJWT, userId: "user-123")
            let cursorResolver = CredentialResolver(home: booleanCursorHome, environment: [:], clock: { self.fixedClockDate })
            let cursorRes = await cursorResolver.resolve(provider: .cursor)
            #expect(cursorRes.discovery.sources[0].status == .unsupportedFormat)
            #expect(cursorRes.candidates.isEmpty)
        }
    }

    @Test("Fresh external file changes are immediately reflected")
    func freshExternalFileChangesReflected() async throws {
        try await withTemporaryHome { home in
            try writeCodexAuth(home: home, token: "token-v1", accountId: "acc-v1")
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })

            let initialRes = await resolver.resolve(provider: .codex)
            let initialCandidate = try #require(initialRes.candidates.first)
            if case let .codex(credentials) = initialCandidate.payload {
                #expect(credentials.accessToken == "token-v1")
                #expect(credentials.accountId == "acc-v1")
            } else {
                Issue.record("Expected .codex payload")
            }

            try writeCodexAuth(home: home, token: "token-v2", accountId: "acc-v2")

            let updatedRes = await resolver.resolve(provider: .codex)
            let updatedCandidate = try #require(updatedRes.candidates.first)
            if case let .codex(credentials) = updatedCandidate.payload {
                #expect(credentials.accessToken == "token-v2")
                #expect(credentials.accountId == "acc-v2")
            } else {
                Issue.record("Expected .codex payload")
            }
        }
    }

    @Test("OMP sticky recency orders active candidate while ignoring malformed or expired stickies")
    func ompStickyRecencyAndMalformedOrExpiredStickyIgnored() async throws {
        try await withTemporaryHome { home in
            let futureExpiry = Int64(self.fixedClockDate.timeIntervalSince1970 + 86400)
            try createOMPDB(
                home: home,
                credentials: [
                    (5, "google-antigravity", nil, [
                        "access": "ag-token-5", "projectId": "project-5", "email": "five@example.invalid"
                    ]),
                    (10, "google-antigravity", nil, [
                        "access": "ag-token-10", "projectId": "project-10", "email": "ten@example.invalid"
                    ])
                ],
                stickies: [
                    ("session:sticky:google-antigravity:older", 5, 100, futureExpiry),
                    ("session:sticky:google-antigravity:newer", 10, 200, futureExpiry)
                ]
            )

            let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
            try executeSQL("""
            INSERT INTO cache VALUES ('session:sticky:google-antigravity:invalid', 'not-json', \(futureExpiry));
            INSERT INTO cache VALUES ('session:sticky:openai-codex:unrelated', '{"credentialId":5,"lastUsedAtMs":9999}', \(futureExpiry));
            INSERT INTO cache VALUES ('session:sticky:google-antigravity:expired', '{"credentialId":5,"lastUsedAtMs":8888}', 0);
            INSERT INTO cache VALUES ('session:sticky:google-antigravity:overflow', '{"credentialId":1e100,"lastUsedAtMs":9000}', \(futureExpiry));
            INSERT INTO cache VALUES ('session:sticky:google-antigravity:fractional', '{"credentialId":5.5,"lastUsedAtMs":9000}', \(futureExpiry));
            """, at: dbURL)

            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })
            let res = await resolver.resolve(provider: .antigravity)
            #expect(res.candidates.count == 2)
            #expect(res.candidates[0].rowID == 10)
            #expect(res.candidates[1].rowID == 5)

            try executeSQL("""
            UPDATE cache SET value = '{"credentialId":5,"lastUsedAtMs":300}'
            WHERE key = 'session:sticky:google-antigravity:older';
            """, at: dbURL)

            let updatedRes = await resolver.resolve(provider: .antigravity)
            #expect(updatedRes.candidates.count == 2)
            #expect(updatedRes.candidates[0].rowID == 5)
            #expect(updatedRes.candidates[1].rowID == 10)
        }
    }

    @Test("Descriptor JSON contains no sentinel secrets or raw error payloads")
    func noSecretsOrRawErrorsInDescriptorJSON() async throws {
        try await withTemporaryHome { home in
            let sentinelSecretToken = "SECRET_SENTINEL_BEARER_X987"
            let sentinelSecretKey = "SECRET_SENTINEL_API_KEY_Y654"

            try writeCodexAuth(home: home, token: sentinelSecretToken, accountId: "codex-account")
            try writeClaudeCredentials(home: home, token: sentinelSecretToken)
            try createCursorDB(home: home, accessToken: sentinelSecretToken, userId: "cursor-account")
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", nil, [
                    "access": sentinelSecretToken,
                    "projectId": "ag-project",
                    "email": "user@example.invalid"
                ]),
                (2, "openrouter", nil, [
                    "key": sentinelSecretKey
                ])
            ])

            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": sentinelSecretKey],
                clock: { self.fixedClockDate }
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            for provider in ProviderType.allCases {
                let discovery = await resolver.discover(provider: provider)
                let data = try encoder.encode(discovery)
                let jsonString = try #require(String(data: data, encoding: .utf8))

                #expect(!jsonString.contains(sentinelSecretToken))
                #expect(!jsonString.contains(sentinelSecretKey))
                #expect(!jsonString.localizedCaseInsensitiveContains("NSFileRead"))
                #expect(!jsonString.localizedCaseInsensitiveContains("sqlite3"))
                #expect(!jsonString.localizedCaseInsensitiveContains("syntax error"))
            }
            let unreadableResolver = CredentialResolver(
                home: home, environment: [:], clock: { self.fixedClockDate },
                readFile: { _ in
                    throw NSError(
                        domain: "Synthetic", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "SECRET_SENTINEL_ERROR_Z321"]
                    )
                }
            )
            let unreadable = await unreadableResolver.discover(provider: .codex)
            #expect(unreadable.sources[0].status == .unreadable)
            let encodedError = try #require(String(data: encoder.encode(unreadable), encoding: .utf8))
            #expect(!encodedError.contains("SECRET_SENTINEL_ERROR_Z321"))
        }
    }

    @Test("Sources remain byte for byte unchanged after discovery and resolution")
    func sourcesByteForByteUnchangedAfterDiscoveryAndResolution() async throws {
        try await withTemporaryHome { home in
            try writeCodexAuth(home: home, token: "codex-token", accountId: "codex-acc")
            try writeClaudeCredentials(home: home, token: "claude-token")
            try createCursorDB(home: home, accessToken: "cursor-token", userId: "cursor-user")
            try createOMPDB(home: home, credentials: [
                (1, "google-antigravity", nil, [
                    "access": "ag-token", "projectId": "ag-proj", "email": "ag@example.invalid"
                ]),
                (2, "openrouter", nil, [
                    "key": "or-token"
                ])
            ])

            let files = [
                home.appendingPathComponent(".codex/auth.json"),
                home.appendingPathComponent(".claude/.credentials.json"),
                home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
                home.appendingPathComponent(".omp/agent/agent.db")
            ]

            var beforeData: [URL: Data] = [:]
            for file in files {
                beforeData[file] = try Data(contentsOf: file)
            }

            let resolver = CredentialResolver(
                home: home,
                environment: ["OPENROUTER_API_KEY": "env-key"],
                clock: { self.fixedClockDate }
            )

            for provider in ProviderType.allCases {
                _ = await resolver.discover(provider: provider)
                _ = await resolver.resolve(provider: provider)
            }

            for file in files {
                let afterData = try Data(contentsOf: file)
                #expect(afterData == beforeData[file])
            }
        }
    }

    @Test("File read IO never executes on the main thread")
    func readIONeverRunsOnMainThread() async throws {
        try await withTemporaryHome { home in
            try writeCodexAuth(home: home, token: "codex-token", accountId: "codex-acc")
            try writeClaudeCredentials(home: home, token: "claude-token")

            final class ThreadCheckRecorder: @unchecked Sendable {
                var wasMainThread = false
                private let lock = NSLock()

                func record() {
                    lock.lock()
                    defer { lock.unlock() }
                    if Thread.isMainThread {
                        wasMainThread = true
                    }
                }

                var didRunOnMainThread: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return wasMainThread
                }
            }

            let recorder = ThreadCheckRecorder()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate }, readFile: { url in
                recorder.record()
                return try Data(contentsOf: url)
            })

            let codex = await resolver.resolve(provider: .codex)
            let claude = await resolver.resolve(provider: .claude)
            #expect(codex.candidates.first?.reference?.accountID == "codex-acc")
            #expect(claude.discovery.sources[0].status == .availableLocally)

            #expect(!recorder.didRunOnMainThread)
        }
    }

    @Test("Same token across different sources retains distinct source association")
    func sameTokenFromDifferentSourcesRetainsSourceAssociation() async throws {
        try await withTemporaryHome { home in
            let sharedToken = "shared-duplicate-token"
            try writeCodexAuth(home: home, token: sharedToken, accountId: "native-account")
            try createOMPDB(home: home, credentials: [
                (1, "openai-codex", nil, [
                    "access": sharedToken,
                    "accountId": "omp-account"
                ])
            ])

            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })
            let res = await resolver.resolve(provider: .codex)

            #expect(res.candidates.count == 2)
            let nativeCandidate = try #require(res.candidates.first(where: { $0.sourceID == "native.codex-auth" }))
            let ompCandidate = try #require(res.candidates.first(where: { $0.sourceID == "omp.agent-db" }))

            #expect(nativeCandidate.reference?.accountID == "native-account")
            #expect(ompCandidate.reference?.accountID == "omp-account")
        }
    }

    @Test("Selection filters accurately by source and pinned account")
    func selectionFiltersBySourceAndAccount() async throws {
        try await withTemporaryHome { home in
            try writeCodexAuth(home: home, token: "native-token", accountId: "native-acc")
            try createOMPDB(home: home, credentials: [
                (1, "openai-codex", nil, [
                    "access": "omp-token-1", "accountId": "omp-acc-1"
                ]),
                (2, "openai-codex", nil, [
                    "access": "omp-token-2", "accountId": "omp-acc-2"
                ])
            ])

            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })

            let automaticRes = await resolver.resolve(provider: .codex, selection: .automatic)
            #expect(automaticRes.candidates.count == 3)

            let nativeSourceOnly = await resolver.resolve(
                provider: .codex,
                selection: .source("native.codex-auth")
            )
            #expect(nativeSourceOnly.candidates.count == 1)
            #expect(nativeSourceOnly.candidates[0].sourceID == "native.codex-auth")

            let ompSourceOnly = await resolver.resolve(
                provider: .codex,
                selection: .source("omp.agent-db")
            )
            #expect(ompSourceOnly.candidates.count == 2)
            for c in ompSourceOnly.candidates {
                #expect(c.sourceID == "omp.agent-db")
            }

            let pinnedAccount = await resolver.resolve(
                provider: .codex,
                selection: .source("omp.agent-db", accountID: "omp-acc-2")
            )
            #expect(pinnedAccount.candidates.count == 1)
            #expect(pinnedAccount.candidates[0].reference?.accountID == "omp-acc-2")

            let nonexistentAccount = await resolver.resolve(
                provider: .codex,
                selection: .source("omp.agent-db", accountID: "nonexistent")
            )
            #expect(nonexistentAccount.candidates.isEmpty)
        }
    }

    @Test("Minimal legacy and versioned OMP schemas are both supported")
    func minimalAndVersionedOMPSchemasSupported() async throws {
        try await withTemporaryHome { home in
            let minimalHome = home.appendingPathComponent("minimal")
            try createOMPDB(
                home: minimalHome,
                versioned: false,
                credentials: [
                    (1, "openai-codex", nil, ["access": "minimal-token", "accountId": "min-acc"])
                ]
            )
            let minimalResolver = CredentialResolver(home: minimalHome, environment: [:], clock: { self.fixedClockDate })
            let minimalRes = await minimalResolver.resolve(provider: .codex)
            let minCandidate = try #require(minimalRes.candidates.first(where: { $0.sourceID == "omp.agent-db" }))
            if case let .codex(creds) = minCandidate.payload {
                #expect(creds.accessToken == "minimal-token")
                #expect(creds.accountId == "min-acc")
            } else {
                Issue.record("Expected .codex payload")
            }

            let versionedHome = home.appendingPathComponent("versioned")
            try createOMPDB(
                home: versionedHome,
                versioned: true,
                credentials: [
                    (1, "openai-codex", nil, ["access": "versioned-token", "accountId": "ver-acc"])
                ]
            )
            let versionedResolver = CredentialResolver(home: versionedHome, environment: [:], clock: { self.fixedClockDate })
            let versionedRes = await versionedResolver.resolve(provider: .codex)
            let verCandidate = try #require(versionedRes.candidates.first(where: { $0.sourceID == "omp.agent-db" }))
            if case let .codex(creds) = verCandidate.payload {
                #expect(creds.accessToken == "versioned-token")
                #expect(creds.accountId == "ver-acc")
            } else {
                Issue.record("Expected .codex payload")
            }
        }
    }


    @Test("Invalid OMP records cannot hide an eligible credential")
    func invalidOMPRecordsPreserveEligibleCredentials() async throws {
        try await withTemporaryHome { home in
            let now = self.fixedClockDate.timeIntervalSince1970
            try createOMPDB(home: home, credentials: [
                (1, "openai-codex", nil, ["access": makeJWT(claims: ["exp": now + 1000]), "accountId": "eligible"]),
                (2, "openai-codex", nil, ["access": "expired-bearer", "accountId": "expired", "expires": now * 1000]),
                (3, "openai-codex", nil, ["access": "malformed", "expires": "tomorrow"]),
                (4, "openai-codex", nil, ["access": "wrong-type"]),
                (5, "openai-codex", nil, ["access": "corrupt"]),
                (6, "openai-codex", "", ["access": "disabled-bearer", "accountId": "disabled"])
            ])
            let databaseURL = home.appendingPathComponent(".omp/agent/agent.db")
            try executeSQL("""
            UPDATE auth_credentials SET credential_type = 'api_key' WHERE id = 4;
            UPDATE auth_credentials SET data = 'invalid-json' WHERE id = 5;
            """, at: databaseURL)
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })
            let resolution = await resolver.resolve(provider: .codex)
            #expect(resolution.candidates.map { $0.reference?.accountID } == ["eligible"])
            let source = try #require(resolution.discovery.sources.first { $0.id == "omp.agent-db" })
            #expect(source.status == .availableLocally)
            let accounts = Dictionary(uniqueKeysWithValues: source.accounts.map { ($0.reference.accountID, $0.status) })
            #expect(accounts == ["eligible": .availableLocally, "expired": .expired, "disabled": .disabled])
        }
    }

    @Test("Codex rejects either expired clock while ranking by JWT expiry")
    func codexDeclaredExpiryAndJWTRanking() async throws {
        try await withTemporaryHome { home in
            let now = self.fixedClockDate.timeIntervalSince1970
            try writeCodexAuth(home: home, token: makeJWT(claims: ["exp": now + 100]), accountId: "native")
            try createOMPDB(home: home, credentials: [
                (1, "openai-codex", nil, [
                    "access": makeJWT(claims: ["exp": now + 200]), "expires": (now + 1) * 1000, "accountId": "omp"
                ]),
                (2, "openai-codex", nil, [
                    "access": makeJWT(claims: ["exp": now + 300]), "expires": now * 1000, "accountId": "expired-file"
                ]),
                (3, "openai-codex", nil, [
                    "access": makeJWT(claims: ["exp": now]), "expires": (now + 300) * 1000, "accountId": "expired-jwt"
                ])
            ])
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedClockDate })
            let resolution = await resolver.resolve(provider: .codex)
            #expect(resolution.candidates.map { $0.reference?.accountID } == ["omp", "native"])
        }
    }

    private func withTemporaryHome<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialSourcesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        return try await body(url)
    }

    private func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeCodexAuth(home: URL, token: String, accountId: String? = nil) throws {
        let fileURL = home.appendingPathComponent(".codex/auth.json")
        try createDirectory(at: fileURL.deletingLastPathComponent())
        var tokens: [String: Any] = ["access_token": token]
        if let accountId {
            tokens["account_id"] = accountId
        }
        let dict = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func writeClaudeCredentials(
        home: URL,
        token: String,
        expiresAt: Int64? = nil,
        subscriptionType: String? = nil
    ) throws {
        let fileURL = home.appendingPathComponent(".claude/.credentials.json")
        try createDirectory(at: fileURL.deletingLastPathComponent())
        var oauth: [String: Any] = ["accessToken": token]
        if let expiresAt {
            oauth["expiresAt"] = expiresAt
        }
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
        versioned: Bool = true,
        credentials: [(Int64, String, String?, [String: Any])],
        stickies: [(String, Int64, Double, Int64)] = []
    ) throws {
        let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
        try createDirectory(at: dbURL.deletingLastPathComponent())
        var sql: String
        if versioned {
            sql = """
            CREATE TABLE auth_credentials (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider TEXT,
                credential_type TEXT,
                data TEXT,
                disabled_cause TEXT,
                identity_key TEXT,
                created_at INTEGER,
                updated_at INTEGER
            );
            CREATE TABLE cache (
                key TEXT PRIMARY KEY,
                value TEXT,
                expires_at INTEGER
            );
            """
        } else {
            sql = """
            CREATE TABLE auth_credentials (
                id INTEGER PRIMARY KEY,
                provider TEXT NOT NULL,
                disabled_cause TEXT,
                data TEXT NOT NULL
            );
            CREATE TABLE cache (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                expires_at INTEGER NOT NULL
            );
            """
        }

        for (id, provider, disabledCause, data) in credentials {
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let jsonString = String(data: jsonData, encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
            let disabled = disabledCause.map { "'\($0)'" } ?? "NULL"
            if versioned {
                let credentialType = provider == "openrouter" ? "api_key" : "oauth"
                sql += """
                \nINSERT INTO auth_credentials (id, provider, credential_type, data, disabled_cause)
                VALUES (\(id), '\(provider)', '\(credentialType)', '\(jsonString)', \(disabled));
                """
            } else {
                sql += """
                \nINSERT INTO auth_credentials (id, provider, disabled_cause, data)
                VALUES (\(id), '\(provider)', \(disabled), '\(jsonString)');
                """
            }
        }

        for (key, credentialId, lastUsedAtMs, expiresAt) in stickies {
            let value = "{\"credentialId\":\(credentialId),\"lastUsedAtMs\":\(lastUsedAtMs)}"
            sql += """
            \nINSERT INTO cache (key, value, expires_at)
            VALUES ('\(key)', '\(value)', \(expiresAt));
            """
        }

        try executeSQL(sql, at: dbURL)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(db) }
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
}

