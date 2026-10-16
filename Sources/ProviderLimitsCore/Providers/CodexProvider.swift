import Foundation

public struct CodexCredentials: Sendable {
    public let accessToken: String
    public let accountId: String?

    public init(accessToken: String, accountId: String? = nil) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

public struct CodexProvider: CredentialUsageClient, Sendable {
    public let providerType: ProviderType = .codex
    public let credentialResolver: CredentialResolver
    private let session: URLSession

    private static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(
        resolver: CredentialResolver = CredentialResolver(),
        session: URLSession = .shared
    ) {
        self.credentialResolver = resolver
        self.session = session
    }

    public func fetchUsage(selection: CredentialSelection = .automatic) async throws -> ProviderUsageSnapshot {
        try await fetchSelectedUsage(selection: selection)
    }

    func fetchUsage(using candidate: CredentialCandidate) async throws -> ProviderUsageSnapshot {
        guard case let .codex(credentials) = candidate.payload else {
            throw ProviderClientError.invalidResponse(.codex, "Unsupported credential payload for Codex")
        }
        return try await fetchLiveUsage(credentials: credentials)
    }

    private func fetchLiveUsage(credentials: CodexCredentials) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.codex, "Missing HTTP response")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.codex, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.codex, "HTTP \(httpResponse.statusCode)")
        }

        return try parseUsagePayload(data: data)
    }

    public func parseUsagePayload(data: Data) throws -> ProviderUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidResponse(.codex, "Invalid JSON payload")
        }
        return try parseUsagePayload(json: json)
    }

    public static func parseCredentials(data: Data) -> CodexCredentials? {
        CredentialParsing.parseCodexCredentials(data: data)
    }

    public func parseUsagePayload(json: [String: Any]) throws -> ProviderUsageSnapshot {
        let planRaw = json["plan_type"] as? String ?? "plus"
        let planName: String
        if planRaw.localizedCaseInsensitiveContains("plus") {
            planName = "ChatGPT Plus / Codex"
        } else if planRaw.localizedCaseInsensitiveContains("pro") {
            planName = "ChatGPT Pro / Codex"
        } else if planRaw.localizedCaseInsensitiveContains("team") {
            planName = "ChatGPT Team / Codex"
        } else if planRaw.localizedCaseInsensitiveContains("enterprise") {
            planName = "ChatGPT Enterprise / Codex"
        } else {
            planName = "ChatGPT \(planRaw.capitalized)"
        }

        var metrics: [LimitMetric] = []
        var seenIds = Set<String>()

        let rateLimit = json["rate_limit"] as? [String: Any] ?? json["rate_limits"] as? [String: Any]
        if let rateLimit {
            parseRateLimitWindows(rateLimit, into: &metrics, seenIds: &seenIds)
        }

        if metrics.isEmpty, let weekly = json["weekly_limit"] as? [String: Any] {
            let remain = numericValue(weekly["percentage_remaining"]) ?? 100.0
            let resetsAtStr = weekly["resets_at"] as? String
            let resetDate = parseResetDateString(resetsAtStr)
            metrics.append(LimitMetric(
                id: "codex_weekly",
                label: "GPT Models · Weekly Limit",
                usedPercentage: 100.0 - remain,
                remainingPercentage: remain,
                resetsAt: resetDate,
                resetInDescription: formatResetDescription(resetDate: resetDate) ?? resetsAtStr,
                status: LimitStatus.evaluate(remainingPercentage: remain)
            ))
        }

        let credits = numericValue((json["credits"] as? [String: Any])?["balance"])
            ?? numericValue(json["credits_remaining"])

        return ProviderUsageSnapshot(
            provider: .codex,
            planName: planName,
            metrics: metrics,
            creditsRemaining: credits
        )
    }

    private func parseRateLimitWindows(
        _ rateLimit: [String: Any],
        into metrics: inout [LimitMetric],
        seenIds: inout Set<String>
    ) {
        let windowKeys = [
            "primary_window", "secondary_window",
            "five_hour", "weekly",
            "primary", "secondary"
        ]
        for key in windowKeys {
            guard let window = rateLimit[key] as? [String: Any],
                  let metric = parseRateLimitWindow(window, key: key),
                  seenIds.insert(metric.id).inserted else { continue }
            metrics.append(metric)
        }
    }

    private func parseRateLimitWindow(
        _ window: [String: Any],
        key: String
    ) -> LimitMetric? {
        let usedPct: Double
        if let used = numericValue(window["used_percent"] ?? window["usedPercent"]) {
            usedPct = used
        } else if let remaining = numericValue(
            window["percent_left"] ?? window["percentage_remaining"]
        ) {
            usedPct = 100.0 - remaining
        } else {
            usedPct = 0.0
        }
        let remainPct = max(0.0, min(100.0, 100.0 - usedPct))
        let classified = classifyRateLimitWindow(
            key: key,
            windowSeconds: numericValue(window["limit_window_seconds"])
        )
        let resetDate = parseWindowResetDate(window)
        return LimitMetric(
            id: classified.id,
            label: classified.label,
            usedPercentage: usedPct,
            remainingPercentage: remainPct,
            resetsAt: resetDate,
            resetInDescription: formatResetDescription(resetDate: resetDate),
            status: LimitStatus.evaluate(remainingPercentage: remainPct)
        )
    }

    private func classifyRateLimitWindow(
        key: String,
        windowSeconds: Double?
    ) -> (id: String, label: String) {
        let isFiveHour: Bool
        if let windowSeconds {
            isFiveHour = windowSeconds <= 12 * 3600
        } else {
            let lower = key.lowercased()
            isFiveHour = !(lower.contains("week") || lower.contains("secondary"))
        }

        if isFiveHour {
            return ("codex_5hour", "GPT Models · 5-Hour Limit")
        } else {
            return ("codex_weekly", "GPT Models · Weekly Limit")
        }
    }

    private func parseWindowResetDate(_ window: [String: Any]) -> Date? {
        if let resetAt = numericValue(window["reset_at"] ?? window["resetsAt"]) {
            let seconds = resetAt > 10_000_000_000 ? resetAt / 1000.0 : resetAt
            return Date(timeIntervalSince1970: seconds)
        }
        if let resetMs = numericValue(window["reset_time_ms"]) {
            return Date(timeIntervalSince1970: resetMs / 1000.0)
        }
        return nil
    }

    private func parseResetDateString(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let timestamp = Double(string) {
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1000.0 : timestamp
            return Date(timeIntervalSince1970: seconds)
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return isoFormatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func formatResetDescription(resetDate: Date?) -> String? {
        guard let resetDate else { return nil }
        let interval = resetDate.timeIntervalSinceNow
        guard interval > 0 else { return "Resets soon" }
        let days = Int(interval / 86400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        if days > 0 {
            return hours > 0 ? "\(days) days, \(hours) hours" : "\(days) days"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours) hours, \(minutes) minutes" : "\(hours) hours"
        } else if minutes > 0 {
            return "\(minutes) minutes"
        }
        return "Resets soon"
    }

    public func parseLocalAuth(data: Data) throws -> ProviderUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderUsageSnapshot.empty(for: .codex)
        }
        if let usageObj = json["usage"] as? [String: Any] {
            return try parseUsagePayload(json: usageObj)
        }
        return ProviderUsageSnapshot.empty(for: .codex)
    }
}
