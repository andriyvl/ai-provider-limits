import Foundation
import ProviderLimitsCore

final class SmokeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handledKey = "SmokeURLProtocolHandledKey"
    private static let lock = NSLock()

    static var recordedRequests: [URLRequest] = []
    static var unexpectedEndpoints: [URL] = []
    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    private static var isSuspended = false
    private static var suspendedProvider: ProviderType?
    private static var continuations: [CheckedContinuation<Void, Never>] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.removeAll()
        unexpectedEndpoints.removeAll()
        isSuspended = false
        suspendedProvider = nil
        let waiting = continuations
        continuations.removeAll()
        for cont in waiting {
            cont.resume()
        }
    }

    static func suspendRequests(for provider: ProviderType) {
        lock.lock()
        defer { lock.unlock() }
        isSuspended = true
        suspendedProvider = provider
    }

    static func resumeRequests() {
        lock.lock()
        let waiting = continuations
        continuations.removeAll()
        isSuspended = false
        suspendedProvider = nil
        lock.unlock()

        for cont in waiting {
            cont.resume()
        }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SmokeURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        let capturedRequest = request
        Self.lock.lock()
        Self.recordedRequests.append(capturedRequest)
        Self.lock.unlock()

        guard let url = capturedRequest.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let provider = Self.provider(for: url)

        Task {
            if let provider {
                await Self.awaitSuspensionIfNeeded(provider: provider)
            }

            guard let (status, data, headers) = Self.mockResponse(for: url, request: capturedRequest) else {
                Self.lock.lock()
                Self.unexpectedEndpoints.append(url)
                Self.lock.unlock()
                self.client?.urlProtocol(
                    self,
                    didFailWithError: URLError(
                        .cannotConnectToHost,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected network call intercepted: \(url.absoluteString)"]
                    )
                )
                return
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func awaitSuspensionIfNeeded(provider: ProviderType) async {
        let shouldWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return isSuspended && suspendedProvider == provider
        }()

        if shouldWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    private static func provider(for url: URL) -> ProviderType? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("googleapis.com") { return .antigravity }
        if host.contains("chatgpt.com") { return .codex }
        if host.contains("anthropic.com") { return .claude }
        if host.contains("cursor.com") || host.contains("cursor.sh") { return .cursor }
        if host.contains("openrouter.ai") { return .openRouter }
        return nil
    }

    private static func mockResponse(
        for url: URL,
        request: URLRequest
    ) -> (Int, Data, [String: String])? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        let headers = ["Content-Type": "application/json; charset=utf-8"]

        if host.contains("googleapis.com") {
            if path.contains("loadCodeAssist") {
                let json = "{\"cloudaicompanion_project\": \"proj-synthetic-antigravity\"}"
                return (200, Data(json.utf8), headers)
            }
            if path.contains("retrieveUserQuotaSummary") {
                let json = """
                {
                  "groups": [
                    {
                      "displayName": "Gemini Models",
                      "buckets": [
                        {
                          "bucketId": "gemini-weekly",
                          "displayName": "Weekly Limit Remaining",
                          "window": "weekly",
                          "resetTime": "2026-08-25T14:10:11Z",
                          "description": "Weekly limit",
                          "remainingFraction": 0.85
                        },
                        {
                          "bucketId": "gemini-5h",
                          "displayName": "Five Hour Limit Remaining",
                          "window": "5h",
                          "resetTime": "2026-08-19T18:11:46Z",
                          "description": "5-hour limit",
                          "remainingFraction": 0.95
                        }
                      ]
                    }
                  ]
                }
                """
                return (200, Data(json.utf8), headers)
            }
        }

        if host.contains("chatgpt.com") {
            if path.contains("wham/usage") {
                let json = """
                {
                  "plan_type": "ChatGPT Plus / Codex",
                  "credits_remaining": 0.0,
                  "rate_limit": [
                    {
                      "window": "primary",
                      "used_percentage": 15.0,
                      "remaining_percentage": 85.0,
                      "reset_time": 1791320400
                    },
                    {
                      "window": "secondary",
                      "used_percentage": 25.0,
                      "remaining_percentage": 75.0,
                      "reset_time": 1791576000
                    }
                  ]
                }
                """
                return (200, Data(json.utf8), headers)
            }
        }

        if host.contains("anthropic.com") {
            if path.hasSuffix("/profile") {
                let json = """
                {"organization": {"organization_type": "claude_pro", "rate_limit_tier": "default_claude_pro"}}
                """
                return (200, Data(json.utf8), headers)
            }
            if path.contains("usage") {
                let json = """
                {
                  "plan_name": "Claude Pro",
                  "five_hour": {
                    "utilization": 20.0,
                    "resets_at": "2026-09-10T12:00:00Z"
                  },
                  "seven_day": {
                    "utilization": 30.0,
                    "resets_at": "2026-09-17T12:00:00Z"
                  }
                }
                """
                return (200, Data(json.utf8), headers)
            }
        }

        if host.contains("cursor.com") || host.contains("cursor.sh") {
            if path.contains("usage-summary") {
                let json = """
                {
                  "individualUsage": {
                    "plan": {
                      "name": "pro",
                      "autoRenew": true
                    },
                    "models": {
                      "claude-3.5-sonnet": {
                        "numRequests": 10,
                        "numTokens": 50000
                      }
                    }
                  }
                }
                """
                return (200, Data(json.utf8), headers)
            }
            if path.contains("GetCreditGrantsBalance") {
                let json = "{\"balance\": 150.0}"
                return (200, Data(json.utf8), headers)
            }
            if path.contains("GetSandUsageStatus") {
                let json = "{\"status\": \"ok\"}"
                return (200, Data(json.utf8), headers)
            }
        }

        if host.contains("openrouter.ai") {
            if path.contains("credits") {
                let json = "{\"data\": {\"total_credits\": 100.0, \"total_usage\": 15.0}}"
                return (200, Data(json.utf8), headers)
            }
            if path.contains("auth/key") {
                let json = "{\"data\": {\"label\": \"synthetic-openrouter-key\", \"limit\": 50.0, \"usage\": 10.0}}"
                return (200, Data(json.utf8), headers)
            }
        }

        return nil
    }
}
