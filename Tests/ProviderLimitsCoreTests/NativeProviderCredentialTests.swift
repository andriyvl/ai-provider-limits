import Foundation
import SQLite3
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ProviderLimitsCore

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var interceptedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.interceptedRequests.append(request)
        guard let handler = Self.requestHandler else {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://unknown.local")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        interceptedRequests.removeAll()
    }
}

@Suite("Native Provider Credential Tests", .serialized)
struct NativeProviderCredentialTests {
    private let fixedDate = Date(timeIntervalSince1970: 1791316800)

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func withTemporaryHome<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeProviderCredentialTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        return try await body(url)
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

    private func encodeVarint(_ value: UInt64) -> Data {
        var val = value
        var bytes = [UInt8]()
        repeat {
            var b = UInt8(val & 0x7F)
            val >>= 7
            if val > 0 { b |= 0x80 }
            bytes.append(b)
        } while val > 0
        return Data(bytes)
    }

    private func encodeField(number: Int, wireType: Int, data: Data) -> Data {
        let tag = UInt64((number << 3) | wireType)
        var result = encodeVarint(tag)
        if wireType == 2 {
            result.append(encodeVarint(UInt64(data.count)))
            result.append(data)
        } else {
            result.append(data)
        }
        return result
    }

    private func encodeVarintField(number: Int, value: UInt64) -> Data {
        let tag = UInt64((number << 3) | 0)
        var result = encodeVarint(tag)
        result.append(encodeVarint(value))
        return result
    }

    private func buildNativeOAuthBlob(accessToken: String, expirySeconds: UInt64, isGCPTOS: Bool) -> Data {
        var tokenInfoData = Data()
        tokenInfoData.append(encodeField(number: 1, wireType: 2, data: Data(accessToken.utf8)))
        tokenInfoData.append(encodeField(number: 2, wireType: 2, data: Data("Bearer".utf8)))
        tokenInfoData.append(encodeField(number: 3, wireType: 2, data: Data("refresh".utf8)))
        let timestampData = encodeVarintField(number: 1, value: expirySeconds)
        tokenInfoData.append(encodeField(number: 4, wireType: 2, data: timestampData))
        tokenInfoData.append(encodeVarintField(number: 6, value: isGCPTOS ? 1 : 0))

        let tokenInfoBase64 = tokenInfoData.base64EncodedString()
        var rowData = Data()
        rowData.append(encodeField(number: 1, wireType: 2, data: Data(tokenInfoBase64.utf8)))

        var mapEntryData = Data()
        mapEntryData.append(encodeField(number: 1, wireType: 2, data: Data("oauthTokenInfoSentinelKey".utf8)))
        mapEntryData.append(encodeField(number: 2, wireType: 2, data: rowData))

        var topicData = Data()
        topicData.append(encodeField(number: 1, wireType: 2, data: mapEntryData))
        return topicData.base64EncodedData()
    }

    private func createNativeAntigravityDB(
        home: URL,
        accessToken: String,
        expirySeconds: UInt64,
        isGCPTOS: Bool,
        userStatusEmail: String? = nil
    ) throws {
        let dbURL = home.appendingPathComponent("Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let blob = buildNativeOAuthBlob(accessToken: accessToken, expirySeconds: expirySeconds, isGCPTOS: isGCPTOS)
        let blobBase64String = blob.base64EncodedString()

        var sql = """
        CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        INSERT INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.oauthToken', '\(blobBase64String)');
        """
        if let email = userStatusEmail {
            sql += "\nINSERT INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.userStatus', '{\"email\":\"\(email)\"}');"
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2)
        }
    }

    private func writeCodexAuth(home: URL, token: String, accountId: String? = nil) throws {
        let fileURL = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var tokens: [String: Any] = ["access_token": token]
        if let accountId { tokens["account_id"] = accountId }
        let dict = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func writePiAuth(home: URL, records: [String: Any]) throws {
        let fileURL = home.appendingPathComponent(".pi/agent/auth.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    // MARK: - Acceptance Test 1: Native Antigravity lookup -> quota pairing and exact snake_case request
    @Test("Native Antigravity candidate pairs loadCodeAssist and retrieveUserQuotaSummary with snake_case metadata and User-Agent")
    func nativeAntigravityLookupQuotaPairing() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let token = "native-antigravity-secret-token"
            let expiry = UInt64(self.fixedDate.timeIntervalSince1970 + 7200)
            try createNativeAntigravityDB(home: home, accessToken: token, expirySeconds: expiry, isGCPTOS: false)

            let session = makeMockSession()
            let resolver = CredentialResolver(
                home: home,
                environment: [:],
                clock: { self.fixedDate }
            )

            MockURLProtocol.requestHandler = { request in
                guard let url = request.url else { throw URLError(.badURL) }

                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "antigravity/2.5.5 darwin/arm64")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

                if url.path.hasSuffix("loadCodeAssist") {
                    #expect(url.host == "cloudcode-pa.googleapis.com")
                    let bodyData = request.httpBody ?? Data()
                    let bodyJSON = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                    let metadata = bodyJSON?["metadata"] as? [String: Any]
                    #expect(metadata?["ide_type"] as? String == "ANTIGRAVITY")
                    #expect(metadata?["ide_name"] as? String == "antigravity")
                    #expect(metadata?["ide_version"] as? String == "2.5.5")

                    let responseJSON: [String: Any] = [
                        "cloudaicompanion_project": "discovered-companion-project-123"
                    ]
                    let respData = try JSONSerialization.data(withJSONObject: responseJSON)
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, respData)
                } else if url.path.hasSuffix("retrieveUserQuotaSummary") {
                    #expect(url.host == "daily-cloudcode-pa.googleapis.com")
                    let bodyData = request.httpBody ?? Data()
                    let bodyJSON = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                    #expect(bodyJSON?["project"] as? String == "discovered-companion-project-123")

                    let quotaJSON: [String: Any] = [
                        "groups": [
                            [
                                "displayName": "Gemini 2.5 Flash",
                                "buckets": [
                                    [
                                        "bucketId": "gemini_weekly",
                                        "remainingFraction": 0.85
                                    ]
                                ]
                            ]
                        ]
                    ]
                    let respData = try JSONSerialization.data(withJSONObject: quotaJSON)
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, respData)
                }

                throw URLError(.badServerResponse)
            }

            let client = AntigravityProvider(resolver: resolver, session: session)
            let snapshot = try await client.fetchUsage(selection: .automatic)

            #expect(snapshot.provider == .antigravity)
            #expect(!snapshot.metrics.isEmpty)
            #expect(snapshot.metrics.first?.remainingPercentage == 85.0)
            #expect(snapshot.provenance?.sourceID == "native.antigravity-ide")
            #expect(snapshot.provenance?.origin == .live)
            #expect(snapshot.provenance?.reference == nil)
            #expect(MockURLProtocol.interceptedRequests.count == 2)
        }
    }

    // MARK: - Acceptance Test 2: Native Antigravity route by isGCPTOS
    @Test("Native Antigravity candidate with isGCPTOS true routes quota summary to cloudcode-pa.googleapis.com")
    func nativeAntigravityGCPTOSRouting() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let token = "native-gcp-token"
            let expiry = UInt64(self.fixedDate.timeIntervalSince1970 + 7200)
            try createNativeAntigravityDB(home: home, accessToken: token, expirySeconds: expiry, isGCPTOS: true)

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                if url.path.hasSuffix("loadCodeAssist") {
                    let responseJSON: [String: Any] = ["cloudaicompanion_project": "gcp-project-999"]
                    let respData = try JSONSerialization.data(withJSONObject: responseJSON)
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, respData)
                } else if url.path.hasSuffix("retrieveUserQuotaSummary") {
                    #expect(url.host == "cloudcode-pa.googleapis.com")
                    let quotaJSON: [String: Any] = [
                        "groups": [
                            [
                                "displayName": "Gemini Models",
                                "buckets": [["bucketId": "gemini_weekly", "remainingFraction": 0.5]]
                            ]
                        ]
                    ]
                    let respData = try JSONSerialization.data(withJSONObject: quotaJSON)
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, respData)
                }
                throw URLError(.badServerResponse)
            }

            let client = AntigravityProvider(resolver: resolver, session: session)
            let snapshot = try await client.fetchUsage(selection: .automatic)
            #expect(snapshot.provider == .antigravity)
            #expect(snapshot.metrics.first?.remainingPercentage == 50.0)
        }
    }

    // MARK: - Acceptance Test 3: Missing project from loadCodeAssist yields failure, no empty/guessed project
    @Test("Native Antigravity missing project does not guess or retry with empty project")
    func nativeAntigravityMissingProjectThrows() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let token = "native-token-no-proj"
            let expiry = UInt64(self.fixedDate.timeIntervalSince1970 + 7200)
            try createNativeAntigravityDB(home: home, accessToken: token, expirySeconds: expiry, isGCPTOS: false)

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                if url.path.hasSuffix("loadCodeAssist") {
                    let emptyProjectJSON: [String: Any] = ["cloudaicompanion_project": ""]
                    let data = try JSONSerialization.data(withJSONObject: emptyProjectJSON)
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
                }
                Issue.record("Should never call quota endpoint when project is missing")
                throw URLError(.badServerResponse)
            }

            let client = AntigravityProvider(resolver: resolver, session: session)
            await #expect(throws: Error.self) {
                try await client.fetchUsage(selection: .automatic)
            }
            #expect(MockURLProtocol.interceptedRequests.count == 1)
        }
    }

    // MARK: - Acceptance Test 4: Native 429 stops immediately without cross-identity hopping
    @Test("Native Antigravity 429 stops immediately and never hops to secondary credential")
    func nativeAntigravity429Stops() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let token = "native-rate-limited-token"
            let expiry = UInt64(self.fixedDate.timeIntervalSince1970 + 7200)
            try createNativeAntigravityDB(home: home, accessToken: token, expirySeconds: expiry, isGCPTOS: false)

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            let client = AntigravityProvider(resolver: resolver, session: session)
            do {
                _ = try await client.fetchUsage(selection: .automatic)
                Issue.record("Expected 429 error to be thrown")
            } catch let failure as CredentialRequestFailure {
                if case .rateLimited = failure.reason {
                    #expect(failure.candidate.sourceID == "native.antigravity-ide")
                } else {
                    Issue.record("Expected rateLimited reason, got \(failure.reason)")
                }
            } catch {
                Issue.record("Expected CredentialRequestFailure, got \(error)")
            }

            #expect(MockURLProtocol.interceptedRequests.count == 1)
        }
    }

    // MARK: - Acceptance Test 5: Unknown native identity has no profile identity attached
    @Test("Native Antigravity does not attach independently persisted UserStatus email as account identity")
    func nativeAntigravityUnknownIdentityNoProfile() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let token = "native-token"
            let expiry = UInt64(self.fixedDate.timeIntervalSince1970 + 7200)
            try createNativeAntigravityDB(
                home: home,
                accessToken: token,
                expirySeconds: expiry,
                isGCPTOS: false,
                userStatusEmail: "unverified-native-profile@gmail.com"
            )

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                guard let url = request.url else { throw URLError(.badURL) }
                if url.path.hasSuffix("loadCodeAssist") {
                    let resp = try JSONSerialization.data(withJSONObject: ["cloudaicompanion_project": "proj-ok"])
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, resp)
                } else {
                    let quotaJSON: [String: Any] = [
                        "groups": [
                            [
                                "displayName": "Gemini Models",
                                "buckets": [["bucketId": "gemini_weekly", "remainingFraction": 1.0]]
                            ]
                        ]
                    ]
                    let resp = try JSONSerialization.data(withJSONObject: quotaJSON)
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, resp)
                }
            }

            let client = AntigravityProvider(resolver: resolver, session: session)
            let snapshot = try await client.fetchUsage(selection: .automatic)

            #expect(snapshot.provenance?.reference == nil)
            #expect(snapshot.provenance?.accountLabel == nil)
            #expect(snapshot.provenance?.sourceID == "native.antigravity-ide")
        }
    }

    // MARK: - Acceptance Test 6: Pinned unavailable makes zero network calls
    @Test("Pinned unavailable source produces empty inactive snapshot with zero network requests")
    func pinnedUnavailableZeroCalls() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { _ in
                Issue.record("Zero network requests expected for pinned unavailable source")
                throw URLError(.badServerResponse)
            }

            let client = AntigravityProvider(resolver: resolver, session: session)
            let snapshot = try await client.fetchUsage(selection: .source("native.antigravity-ide"))

            #expect(snapshot.metrics.isEmpty)
            #expect(!snapshot.isActive)
            #expect(MockURLProtocol.interceptedRequests.isEmpty)
        }
    }

    // MARK: - Acceptance Test 7: Codex ChatGPT-Account-Id header from typed credential
    @Test("Codex attaches ChatGPT-Account-Id from typed credential")
    func codexChatGptAccountIdHeader() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let jwt = makeJWT(claims: ["exp": self.fixedDate.timeIntervalSince1970 + 3600])
            try writeCodexAuth(home: home, token: jwt, accountId: "org-account-987")

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "org-account-987")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

                let payload: [String: Any] = [
                    "plan_type": "pro",
                    "rate_limit": [
                        "primary_window": [
                            "used_percent": 25.0,
                            "limit_window_seconds": 18000.0
                        ]
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (resp, data)
            }

            let client = CodexProvider(resolver: resolver, session: session)
            let snapshot = try await client.fetchUsage(selection: .automatic)

            #expect(snapshot.provider == .codex)
            #expect(snapshot.planName.contains("Pro"))
            #expect(snapshot.metrics.first?.remainingPercentage == 75.0)
            #expect(snapshot.provenance?.reference?.accountID == "org-account-987")
            #expect(snapshot.provenance?.sourceID == "native.codex-auth")
            #expect(MockURLProtocol.interceptedRequests.count == 1)
        }
    }

    // MARK: - Acceptance Test 8: Codex candidate retries non-429 and records actual provenance
    @Test("Codex first candidate fails with 500 second candidate succeeds and preserves actual provenance")
    func codexFirstFailsSecondSucceedsProvenance() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let newerExp = self.fixedDate.timeIntervalSince1970 + 7200
            let olderExp = self.fixedDate.timeIntervalSince1970 + 3600

            // Native auth has newer exp -> candidate 1
            let jwt1 = makeJWT(claims: ["exp": newerExp])
            try writeCodexAuth(home: home, token: jwt1, accountId: "native-acc-1")

            // Pi auth has older exp -> candidate 2
            let jwt2 = makeJWT(claims: ["exp": olderExp])
            let piRecords: [String: Any] = [
                "openai-codex": [
                    "type": "oauth",
                    "access": jwt2,
                    "refresh": "ref",
                    "expires": olderExp * 1000,
                    "accountId": "pi-acc-2"
                ]
            ]
            try writePiAuth(home: home, records: piRecords)

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth.contains(jwt1) {
                    let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                    return (resp, Data())
                } else if auth.contains(jwt2) {
                    let payload: [String: Any] = [
                        "plan_type": "plus",
                        "rate_limit": [
                            "primary_window": [
                                "used_percent": 10.0,
                                "limit_window_seconds": 18000.0
                            ]
                        ]
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (resp, data)
                }
                throw URLError(.badServerResponse)
            }

            let client = CodexProvider(resolver: resolver, session: session)
            let snapshot = try await client.fetchUsage(selection: .automatic)

            #expect(snapshot.provider == .codex)
            #expect(snapshot.provenance?.sourceID == "pi.auth-json")
            #expect(snapshot.provenance?.reference?.accountID == "pi-acc-2")
            #expect(snapshot.provenance?.origin == .live)
            #expect(MockURLProtocol.interceptedRequests.count == 2)
        }
    }

    // MARK: - Acceptance Test 9: Codex 429 stops immediately without advancing candidates
    @Test("Codex 429 on first candidate stops traversal immediately")
    func codex429StopsImmediately() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let newerExp = self.fixedDate.timeIntervalSince1970 + 7200
            let olderExp = self.fixedDate.timeIntervalSince1970 + 3600

            let jwt1 = makeJWT(claims: ["exp": newerExp])
            try writeCodexAuth(home: home, token: jwt1, accountId: "native-acc-1")

            let jwt2 = makeJWT(claims: ["exp": olderExp])
            let piRecords: [String: Any] = [
                "openai-codex": [
                    "type": "oauth",
                    "access": jwt2,
                    "refresh": "ref",
                    "expires": olderExp * 1000,
                    "accountId": "pi-acc-2"
                ]
            ]
            try writePiAuth(home: home, records: piRecords)

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                let resp = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }

            let client = CodexProvider(resolver: resolver, session: session)
            do {
                _ = try await client.fetchUsage(selection: .automatic)
                Issue.record("Expected 429 to throw")
            } catch let failure as CredentialRequestFailure {
                if case .rateLimited = failure.reason {
                    #expect(failure.candidate.sourceID == "native.codex-auth")
                } else {
                    Issue.record("Expected rateLimited reason")
                }
            } catch {
                Issue.record("Expected CredentialRequestFailure, got \(error)")
            }

            #expect(MockURLProtocol.interceptedRequests.count == 1)
        }
    }

    // MARK: - Acceptance Test 10: Secret-free errors on failures
    @Test("Errors thrown by provider clients contain no bearer tokens or secret sentinels")
    func secretFreeErrorsOnFailure() async throws {
        try await withTemporaryHome { home in
            MockURLProtocol.reset()
            defer { MockURLProtocol.reset() }

            let secretToken = "SUPER_SECRET_TOKEN_SENTINEL_XYZ123"
            let jwt = makeJWT(claims: ["exp": self.fixedDate.timeIntervalSince1970 + 3600, "token": secretToken])
            try writeCodexAuth(home: home, token: jwt, accountId: "secret-acc")

            let session = makeMockSession()
            let resolver = CredentialResolver(home: home, environment: [:], clock: { self.fixedDate })

            MockURLProtocol.requestHandler = { request in
                let resp = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
                return (resp, Data("Internal Bad Gateway with secret headers".utf8))
            }

            let client = CodexProvider(resolver: resolver, session: session)
            do {
                _ = try await client.fetchUsage(selection: .automatic)
                Issue.record("Expected failure")
            } catch {
                let errorString = String(describing: error)
                #expect(!errorString.contains(secretToken))
                #expect(!errorString.contains(jwt))
            }
        }
    }
}
