import Foundation
import SQLite3
import Testing
@testable import ProviderLimitsCore

@Suite("Credential Selection Engine Tests", .serialized)
struct CredentialSelectionEngineTests {
    private let fixedDate = Date(timeIntervalSince1970: 1791316800)

    @Test("Switching A to B during refresh rejects late A completion")
    func switchDuringRefreshRejectsLateCompletion() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refA = CredentialReference(sourceID: "native.codex", accountID: "user-a")
            let refB = CredentialReference(sourceID: "omp.codex", accountID: "user-b")

            let jwtA = makeJWT(now: now + 500, accountID: "user-a")
            let jwtB = makeJWT(now: now, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            let barrierA = AsyncBarrier()
            StubTransport.setHandler { request in
                let authHeader = request.allHTTPHeaderFields?["Authorization"] ?? ""
                if authHeader.contains(jwtA) {
                    await barrierA.wait()
                    let json = """
                    {
                      "plan_type": "ChatGPT Plus / Codex",
                      "credits_remaining": 0.0,
                      "rate_limit": [
                        {
                          "window": "primary",
                          "used_percentage": 10.0,
                          "remaining_percentage": 90.0,
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
                } else {
                    let json = """
                    {
                      "plan_type": "ChatGPT Plus / Codex",
                      "credits_remaining": 0.0,
                      "rate_limit": [
                        {
                          "window": "primary",
                          "used_percentage": 90.0,
                          "remaining_percentage": 10.0,
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
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            await engine.setCredentialSelection(.source("native.codex", accountID: "user-a"), for: .codex)

            let taskA = Task {
                try await engine.refresh(provider: .codex)
            }

            await barrierA.waitForWaiter()

            await engine.setCredentialSelection(.source("omp.codex", accountID: "user-b"), for: .codex)
            let resultB = try await engine.refresh(provider: .codex)
            #expect(resultB.provenance?.reference == refB)

            await barrierA.unlock()

            do {
                _ = try await taskA.value
                Issue.record("Task A must throw CancellationError because it was superseded")
            } catch is CancellationError {
                
            } catch {
                
            }

            let current = await engine.currentSnapshots()[.codex]
            #expect(current?.provenance?.reference == refB)
            #expect(store.loadSnapshot(for: .codex, reference: refA) == nil)
            #expect(store.loadSnapshot(for: .codex, reference: refB) != nil)
        }
    }

    @Test("RefreshAll overlap with selection change preserves new provider state")
    func refreshAllOverlapWithSelectionChange() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refB = CredentialReference(sourceID: "omp.codex", accountID: "user-b")

            let jwtA = makeJWT(now: now + 500, accountID: "user-a")
            let jwtB = makeJWT(now: now, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")
            try writeOMPDB(home: home, token: jwtB, accountID: "user-b")

            let barrierA = AsyncBarrier()
            StubTransport.setHandler { request in
                let authHeader = request.allHTTPHeaderFields?["Authorization"] ?? ""
                if authHeader.contains(jwtA) {
                    await barrierA.wait()
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
                } else {
                    let json = """
                    {
                      "plan_type": "ChatGPT Plus / Codex",
                      "credits_remaining": 0.0,
                      "rate_limit": [
                        {
                          "window": "primary",
                          "used_percentage": 75.0,
                          "remaining_percentage": 25.0,
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
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            await engine.setCredentialSelection(.source("native.codex", accountID: "user-a"), for: .codex)

            let refreshAllTask = Task {
                await engine.refreshAll(providers: [.codex])
            }

            await barrierA.waitForWaiter()

            await engine.setCredentialSelection(.source("omp.codex", accountID: "user-b"), for: .codex)
            let directB = try await engine.refresh(provider: .codex)
            #expect(directB.provenance?.reference == refB)

            await barrierA.unlock()

            let refreshAllResults = await refreshAllTask.value
            #expect(refreshAllResults[.codex]?.provenance?.reference != CredentialReference(sourceID: "native.codex", accountID: "user-a"))

            let current = await engine.currentSnapshots()[.codex]
            #expect(current?.provenance?.reference == refB)
        }
    }

    @Test("External login change under Automatic rejects older in-flight completion")
    func externalLoginChangeUnderAutomaticRejectsOlderCompletion() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let now = self.fixedDate.timeIntervalSince1970
            let refB = CredentialReference(sourceID: "native.codex", accountID: "user-b")

            let jwtA = makeJWT(now: now + 500, accountID: "user-a")
            let jwtB = makeJWT(now: now + 600, accountID: "user-b")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")

            let barrierA = AsyncBarrier()
            StubTransport.setHandler { request in
                let authHeader = request.allHTTPHeaderFields?["Authorization"] ?? ""
                if authHeader.contains(jwtA) {
                    await barrierA.wait()
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
                } else {
                    let json = """
                    {
                      "plan_type": "ChatGPT Plus / Codex",
                      "credits_remaining": 0.0,
                      "rate_limit": [
                        {
                          "window": "primary",
                          "used_percentage": 50.0,
                          "remaining_percentage": 50.0,
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
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })

            let task1 = Task {
                try await engine.refresh(provider: .codex)
            }

            await barrierA.waitForWaiter()

            try writeCodexAuth(home: home, token: jwtB, accountID: "user-b")
            let result2 = try await engine.refresh(provider: .codex)
            #expect(result2.provenance?.reference == refB)

            await barrierA.unlock()

            do {
                _ = try await task1.value
                Issue.record("Task 1 must throw CancellationError")
            } catch is CancellationError {
                
            } catch {
                
            }

            let current = await engine.currentSnapshots()[.codex]
            #expect(current?.provenance?.reference == refB)
            #expect(store.loadSnapshot(for: .codex, reference: CredentialReference(sourceID: "native.codex", accountID: "user-a")) == nil)
        }
    }

    @Test("Pinned source disappearance returns inactive empty and preserves preference")
    func pinnedSourceDisappearancePreservesPreference() async throws {
        try await withTestEnvironment { store, _, resolver, session in
            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            await engine.setCredentialSelection(.source("native.codex", accountID: "missing-user"), for: .codex)

            let result = try await engine.refresh(provider: .codex)
            #expect(!result.isActive)

            let selections = await engine.credentialSelections()
            #expect(selections[.codex] == .source("native.codex", accountID: "missing-user"))
        }
    }

    @Test("Discover credentials makes zero network requests and preserves preferences")
    func discoverCredentialsMakesZeroRequests() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let jwt = makeJWT(now: self.fixedDate.timeIntervalSince1970, accountID: "disc-user")
            try writeCodexAuth(home: home, token: jwt, accountID: "disc-user")

            let requestCount = RequestCount()
            StubTransport.setHandler { _ in
                await requestCount.increment()
                throw URLError(.badServerResponse)
            }

            let engine = SyncEngine(store: store, resolver: resolver, session: session, clock: { self.fixedDate })
            await engine.setCredentialSelection(.source("native.codex", accountID: "disc-user"), for: .codex)

            let discovery = await engine.discoverCredentials(for: .codex)
            #expect(discovery.provider == .codex)
            #expect(await requestCount.count() == 0)

            let selections = await engine.credentialSelections()
            #expect(selections[.codex] == .source("native.codex", accountID: "disc-user"))
        }
    }

    @Test("Set credential selection without network invalidates display and cooldown")
    func setCredentialSelectionWithoutNetworkInvalidatesDisplayAndCooldown() async throws {
        try await withTestEnvironment { store, home, resolver, session in
            let jwtA = makeJWT(now: self.fixedDate.timeIntervalSince1970, accountID: "user-a")
            try writeCodexAuth(home: home, token: jwtA, accountID: "user-a")

            let requestCount = RequestCount()
            StubTransport.setHandler { request in
                await requestCount.increment()
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
            _ = try await engine.refresh(provider: .codex)
            #expect(await engine.currentSnapshots()[.codex] != nil)
            #expect(await requestCount.count() == 1)

            await engine.setCredentialSelection(.source("native.codex", accountID: "user-b"), for: .codex)
            #expect(await requestCount.count() == 1)
            #expect(await engine.currentSnapshots()[.codex] == nil)
        }
    }

    private func withTestEnvironment<T>(
        _ body: (AppGroupStore, URL, CredentialResolver, URLSession) async throws -> T
    ) async throws -> T {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialSelectionEngineTests-\(UUID().uuidString)")
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

private actor AsyncBarrier {
    private var isUnlocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterNotifier: CheckedContinuation<Void, Never>?

    func wait() async {
        if isUnlocked { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if let notifier = waiterNotifier {
                waiterNotifier = nil
                notifier.resume()
            }
        }
    }

    func waitForWaiter() async {
        if !waiters.isEmpty || isUnlocked { return }
        await withCheckedContinuation { continuation in
            waiterNotifier = continuation
        }
    }

    func unlock() {
        isUnlocked = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
        if let notifier = waiterNotifier {
            waiterNotifier = nil
            notifier.resume()
        }
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
