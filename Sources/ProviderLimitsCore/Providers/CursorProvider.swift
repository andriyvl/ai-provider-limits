import Foundation

public struct CursorCredentials: Sendable {
    public let accessToken: String
    public let userId: String
    public let membershipType: String?

    public init(accessToken: String, userId: String, membershipType: String? = nil) {
        self.accessToken = accessToken
        self.userId = userId
        self.membershipType = membershipType
    }
}

public struct SandUsageStatus: Sendable, Equatable {
    public let usedPercentage: Double
    public let resetsAt: Date?
    public let resetInDescription: String?

    public init(
        usedPercentage: Double,
        resetsAt: Date? = nil,
        resetInDescription: String? = nil
    ) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.resetInDescription = resetInDescription
    }
}

public struct CursorProvider: CredentialUsageClient, Sendable {
    public let providerType: ProviderType = .cursor
    public let credentialResolver: CredentialResolver
    private let session: URLSession
    private let summaryBaseURL: URL
    private let creditGrantsURL: URL
    private let sandUsageURL: URL

    public init(
        resolver: CredentialResolver = CredentialResolver(),
        session: URLSession = .shared,
        summaryBaseURL: URL = URL(string: "https://cursor.com/api/usage-summary")!,
        creditGrantsURL: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance")!,
        sandUsageURL: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    ) {
        self.credentialResolver = resolver
        self.session = session
        self.summaryBaseURL = summaryBaseURL
        self.creditGrantsURL = creditGrantsURL
        self.sandUsageURL = sandUsageURL
    }

    public func fetchUsage(selection: CredentialSelection = .automatic) async throws -> ProviderUsageSnapshot {
        try await fetchSelectedUsage(selection: selection)
    }

    func fetchUsage(using candidate: CredentialCandidate) async throws -> ProviderUsageSnapshot {
        guard case let .cursor(credentials) = candidate.payload,
              !credentials.accessToken.isEmpty,
              !credentials.userId.isEmpty else {
            throw ProviderClientError.missingCredentials(.cursor)
        }

        return try await fetchLiveUsage(credentials: credentials)
    }

    private func fetchLiveUsage(credentials: CursorCredentials) async throws -> ProviderUsageSnapshot {
        guard var components = URLComponents(url: summaryBaseURL, resolvingAgainstBaseURL: false) else {
            throw ProviderClientError.invalidResponse(.cursor, "Invalid URL")
        }
        components.queryItems = [URLQueryItem(name: "user", value: credentials.userId)]
        guard let url = components.url else {
            throw ProviderClientError.invalidResponse(.cursor, "Invalid URL")
        }

        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encodedUserId = credentials.userId.addingPercentEncoding(withAllowedCharacters: unreserved),
              !encodedUserId.isEmpty else {
            throw ProviderClientError.invalidResponse(.cursor, "Invalid user identifier")
        }

        let cookieVal = "\(encodedUserId)%3A%3A\(credentials.accessToken)"
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(cookieVal)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        async let creditsTask = fetchCreditGrantsBalance(token: credentials.accessToken)
        async let sandUsageTask = fetchSandUsageStatus(token: credentials.accessToken)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.cursor, "Missing HTTP response")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.cursor, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.cursor, "HTTP \(httpResponse.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidResponse(.cursor, "Invalid JSON")
        }
        let creditsRemaining = await creditsTask
        let sandUsage = await sandUsageTask

        let snapshot = try parseLiveUsageJSON(
            json: json,
            credentials: credentials,
            creditsRemaining: creditsRemaining,
            sandUsage: sandUsage
        )
        guard !snapshot.metrics.isEmpty || snapshot.creditsRemaining != nil else {
            throw ProviderClientError.invalidResponse(.cursor, "Empty usage payload")
        }
        return snapshot
    }

    private func fetchCreditGrantsBalance(token: String) async -> Double? {
        var request = URLRequest(url: creditGrantsURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let hasGrants = json["hasCreditGrants"] as? Bool, hasGrants else {
            return nil
        }

        if let centsStr = json["creditBalanceCents"] as? String, let cents = Double(centsStr) {
            return cents / 100.0
        }
        if let centsNum = json["creditBalanceCents"] as? Double {
            return centsNum / 100.0
        }
        if let centsInt = json["creditBalanceCents"] as? Int {
            return Double(centsInt) / 100.0
        }

        return nil
    }

    public func fetchSandUsageStatus(token: String) async -> SandUsageStatus? {
        var request = URLRequest(url: sandUsageURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseSandUsageStatus(json: json)
    }

    public func parseSandUsageStatus(json: [String: Any]) -> SandUsageStatus? {
        if json["includedLimitZero"] as? Bool == true || json["included_limit_zero"] as? Bool == true {
            return nil
        }

        let used: Double?
        if let num = json["usagePercent"] as? Double ?? json["usage_percent"] as? Double {
            used = num
        } else if let num = json["usagePercent"] as? Int ?? json["usage_percent"] as? Int {
            used = Double(num)
        } else if let str = json["usagePercent"] as? String ?? json["usage_percent"] as? String,
                  let num = Double(str) {
            used = num
        } else if let num = json["used_percentage"] as? Double ?? json["usedPercentage"] as? Double {
            used = num
        } else if let num = json["percentUsed"] as? Double ?? json["percent_used"] as? Double {
            used = num
        } else {
            used = nil
        }

        guard let used else { return nil }

        let rawDate = json["nextResetTimestampUtc"]
            ?? json["next_reset_timestamp_utc"]
            ?? json["nextResetMs"]
            ?? json["next_reset_ms"]
            ?? json["resets_at"]
            ?? json["resetsAt"]

        let resetDate = parseTimestampValue(rawDate)
        let resetDesc = json["resetInDescription"] as? String
            ?? json["reset_in_description"] as? String
            ?? parseBillingEndDescription(resetDate)

        return SandUsageStatus(
            usedPercentage: used,
            resetsAt: resetDate,
            resetInDescription: resetDesc
        )
    }

    private func parseTimestampValue(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let string = value as? String {
            if let date = parseBillingEndDate(string) {
                return date
            }
            if let num = Double(string) {
                let seconds = num > 10_000_000_000 ? num / 1000.0 : num
                return Date(timeIntervalSince1970: seconds)
            }
        } else if let dict = value as? [String: Any] {
            let secondsVal: Double?
            if let sec = dict["seconds"] as? Double {
                secondsVal = sec
            } else if let sec = dict["seconds"] as? Int {
                secondsVal = Double(sec)
            } else if let sec = dict["seconds"] as? String, let num = Double(sec) {
                secondsVal = num
            } else {
                secondsVal = nil
            }
            if let secondsVal {
                let nanos = (dict["nanos"] as? Double)
                    ?? (dict["nanos"] as? Int).map(Double.init)
                    ?? 0.0
                return Date(timeIntervalSince1970: secondsVal + nanos / 1_000_000_000.0)
            }
        } else if let num = value as? Double {
            let seconds = num > 10_000_000_000 ? num / 1000.0 : num
            return Date(timeIntervalSince1970: seconds)
        } else if let num = value as? Int {
            let numDouble = Double(num)
            let seconds = numDouble > 10_000_000_000 ? numDouble / 1000.0 : numDouble
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    public func parseLiveUsageJSON(
        json: [String: Any],
        credentials: CursorCredentials,
        creditsRemaining: Double? = nil,
        sandUsage: SandUsageStatus? = nil
    ) throws -> ProviderUsageSnapshot {
        let plan = credentials.membershipType?.capitalized ?? "Pro"
        let planName = "Included in \(plan)"

        var metrics: [LimitMetric] = []
        let indUsage = json["individualUsage"] as? [String: Any]
        let planUsage = indUsage?["plan"] as? [String: Any]

        let billingEndDate = parseBillingEndDate(json["billingCycleEnd"] as? String)
        let resetDesc = parseBillingEndDescription(billingEndDate)

        if let autoUsed = planUsage?["autoPercentUsed"] as? Double {
            let remain = max(0.0, min(100.0, 100.0 - autoUsed))
            metrics.append(LimitMetric(
                id: "cursor_models",
                label: "Cursor Models · Monthly",
                usedPercentage: autoUsed,
                remainingPercentage: remain,
                resetsAt: billingEndDate,
                resetInDescription: resetDesc,
                status: LimitStatus.evaluate(remainingPercentage: remain)
            ))
        }

        if let apiUsed = planUsage?["apiPercentUsed"] as? Double {
            let remain = max(0.0, min(100.0, 100.0 - apiUsed))
            metrics.append(LimitMetric(
                id: "other_models",
                label: "Other Models · $20 Credits Allowance",
                usedPercentage: apiUsed,
                remainingPercentage: remain,
                resetsAt: billingEndDate,
                resetInDescription: resetDesc,
                status: LimitStatus.evaluate(remainingPercentage: remain)
            ))
        }
        let resolvedSandUsage: SandUsageStatus?
        if let sandUsage {
            resolvedSandUsage = sandUsage
        } else if let nested = json["grok_bot"] as? [String: Any]
            ?? json["grok"] as? [String: Any]
            ?? json["sand_usage"] as? [String: Any]
            ?? json["sandUsage"] as? [String: Any] {
            resolvedSandUsage = parseSandUsageStatus(json: nested)
        } else if json["usagePercent"] != nil || json["usage_percent"] != nil {
            resolvedSandUsage = parseSandUsageStatus(json: json)
        } else {
            resolvedSandUsage = nil
        }

        if let resolvedSandUsage {
            let used = resolvedSandUsage.usedPercentage
            let remain = max(0.0, min(100.0, 100.0 - used))
            let resetsAt = resolvedSandUsage.resetsAt
            let resetInDesc = resolvedSandUsage.resetInDescription ?? parseBillingEndDescription(resetsAt)
            metrics.append(LimitMetric(
                id: "grok_bot",
                label: "Grok Bot · Weekly",
                usedPercentage: used,
                remainingPercentage: remain,
                resetsAt: resetsAt,
                resetInDescription: resetInDesc,
                status: LimitStatus.evaluate(remainingPercentage: remain)
            ))
        }

        let parsedCredits = creditsRemaining ?? (json["credits_remaining"] as? Double) ?? (json["credits"] as? Double)

        return ProviderUsageSnapshot(
            provider: .cursor,
            planName: planName,
            metrics: metrics,
            creditsRemaining: parsedCredits,
            subscriptionEndsAt: billingEndDate
        )
    }

    private func parseBillingEndDate(_ dateStr: String?) -> Date? {
        guard let dateStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
    }

    private func parseBillingEndDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Resets soon" }
        let days = Int(interval / 86400)
        return "\(days) \(days == 1 ? "day" : "days")"
    }

    public func parseUserIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sub"] as? String
    }

    public func parseUsagePayload(data: Data) throws -> ProviderUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderUsageSnapshot.empty(for: .cursor)
        }

        let planName = json["plan"] as? String ?? "Included in Pro"
        let onDemandSpend = json["on_demand_spend"] as? Double ?? 0.0

        var metrics: [LimitMetric] = []
        if let cursorModels = json["cursor_models"] as? [String: Any],
           let used = cursorModels["used_percentage"] as? Double {
            metrics.append(LimitMetric(
                id: "cursor_models",
                label: cursorModels["label"] as? String ?? "Cursor Models · Monthly",
                usedPercentage: used,
                remainingPercentage: max(0.0, 100.0 - used)
            ))
        }

        if let otherModels = json["other_models"] as? [String: Any],
           let used = otherModels["used_percentage"] as? Double {
            metrics.append(LimitMetric(
                id: "other_models",
                label: otherModels["label"] as? String ?? "Other Models · $20 Credits Allowance",
                usedPercentage: used,
                remainingPercentage: max(0.0, 100.0 - used)
            ))
        }
        if let grokBot = json["grok_bot"] as? [String: Any] ?? json["grok"] as? [String: Any],
           let used = grokBot["used_percentage"] as? Double
            ?? grokBot["usedPercentage"] as? Double
            ?? (grokBot["usagePercent"] as? Double)
            ?? (grokBot["usage_percent"] as? Double) {
            let resetsAt = parseBillingEndDate(grokBot["resets_at"] as? String ?? grokBot["resetsAt"] as? String)
            metrics.append(LimitMetric(
                id: "grok_bot",
                label: grokBot["label"] as? String ?? "Grok Bot · Weekly",
                usedPercentage: used,
                remainingPercentage: max(0.0, 100.0 - used),
                resetsAt: resetsAt,
                resetInDescription: grokBot["reset_in_description"] as? String
                    ?? grokBot["resetInDescription"] as? String
                    ?? parseBillingEndDescription(resetsAt)
            ))
        }

        return ProviderUsageSnapshot(
            provider: .cursor,
            planName: planName,
            metrics: metrics,
            creditsRemaining: json["credits_remaining"] as? Double ?? (json["credits"] as? Double),
            onDemandSpend: onDemandSpend
        )
    }
}
