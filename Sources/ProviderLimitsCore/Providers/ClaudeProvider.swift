import Foundation

public struct ClaudeCredentials: Sendable {
    public let accessToken: String
    public let subscriptionType: String?

    public init(accessToken: String, subscriptionType: String? = nil) {
        self.accessToken = accessToken
        self.subscriptionType = subscriptionType
    }
}

public struct ClaudeProvider: AIProviderClient, Sendable {
    public let providerType: ProviderType = .claude
    private let credentialsFileURL: URL?
    private let customToken: String?
    private let customEndpoint: URL?

    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(
        credentialsFileURL: URL? = nil,
        customToken: String? = nil,
        customEndpoint: URL? = nil
    ) {
        self.credentialsFileURL = credentialsFileURL
        self.customToken = customToken
        self.customEndpoint = customEndpoint
    }

    public func fetchUsage() async throws -> ProviderUsageSnapshot {
        if let credentials = resolveCredentials() {
            do {
                return try await fetchLiveUsage(credentials: credentials)
            } catch let error as ProviderClientError {
                if case .rateLimited = error { throw error }
            }
        }

        let credentialsURL = resolveCredentialsURL()
        if let data = try? Data(contentsOf: credentialsURL) {
            return try parseCredentialsOrUsage(data: data)
        }
        return ProviderUsageSnapshot.empty(for: .claude)
    }

    public func resolveCredentials() -> ClaudeCredentials? {
        if let customToken {
            return ClaudeCredentials(accessToken: customToken)
        }
        guard let data = try? Data(contentsOf: resolveCredentialsURL()) else {
            return nil
        }
        return parseCredentials(data: data)
    }

    public func parseCredentials(data: Data) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = json["claudeAiOauth"] as? [String: Any]
        let accessToken = oauth?["accessToken"] as? String
            ?? oauth?["access_token"] as? String
            ?? json["accessToken"] as? String
            ?? json["access_token"] as? String
        guard let accessToken, !accessToken.isEmpty else { return nil }

        let subscriptionType = oauth?["subscriptionType"] as? String
            ?? oauth?["subscription_type"] as? String
            ?? json["subscriptionType"] as? String
            ?? json["subscription_type"] as? String
        return ClaudeCredentials(accessToken: accessToken, subscriptionType: subscriptionType)
    }

    public func parseCredentialsOrUsage(data: Data) throws -> ProviderUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderUsageSnapshot.empty(for: .claude)
        }
        if let usage = json["usage"] as? [String: Any] {
            return try parseUsagePayload(json: usage)
        }
        return ProviderUsageSnapshot(
            provider: .claude,
            planName: "Claude",
            metrics: [],
            isActive: false
        )
    }

    public func parseUsagePayload(
        json: [String: Any],
        planName: String? = nil
    ) throws -> ProviderUsageSnapshot {
        let windows = [
            ("five_hour", "claude_5hour", "5-Hour Session Window"),
            ("seven_day", "claude_weekly", "Weekly Usage Limit"),
            ("seven_day_sonnet", "claude_sonnet", "Sonnet 7-Day Limit"),
            ("seven_day_opus", "claude_opus", "Opus 7-Day Limit")
        ]
        let metrics = windows.compactMap { window -> LimitMetric? in
            let (key, id, label) = window
            guard let usage = json[key] as? [String: Any] else { return nil }
            return parseUsageMetric(usage, id: id, label: label)
        }
        let extraUsage = json["extra_usage"] as? [String: Any]
        let balance = numericValue(extraUsage?["balance"])

        return ProviderUsageSnapshot(
            provider: .claude,
            planName: planName ?? json["plan_name"] as? String ?? "Claude Pro",
            metrics: metrics,
            creditsRemaining: balance,
            isActive: !metrics.isEmpty
        )
    }

    private func fetchLiveUsage(credentials: ClaudeCredentials) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: customEndpoint ?? Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.claude, "Missing HTTP response")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.claude, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.claude, "HTTP \(httpResponse.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidResponse(.claude, "Invalid JSON")
        }
        return try parseUsagePayload(
            json: json,
            planName: planName(for: credentials.subscriptionType)
        )
    }

    private func parseUsageMetric(
        _ usage: [String: Any],
        id: String,
        label: String
    ) -> LimitMetric {
        let utilization = numericValue(usage["utilization"]) ?? 0.0
        let usedPercentage = utilization > 1.0 ? utilization : utilization * 100.0
        let relativeReset = usage["resets_in"] as? String
        let resetDate = parseResetDate(usage["resets_at"] as? String)
            ?? parseRelativeResetDate(relativeReset)
        return LimitMetric(
            id: id,
            label: label,
            usedPercentage: usedPercentage,
            remainingPercentage: 100.0 - usedPercentage,
            resetsAt: resetDate,
            resetInDescription: relativeReset ?? formatResetDescription(resetDate)
        )
    }

    private func resolveCredentialsURL() -> URL {
        if let credentialsFileURL {
            return credentialsFileURL
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        #else
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("claude_credentials.json")
        #endif
    }

    private func parseResetDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func parseRelativeResetDate(_ description: String?) -> Date? {
        guard var cleaned = description?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        for prefix in ["resets in ", "refresh in ", "in "] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        if cleaned.hasSuffix(" remaining") {
            cleaned = String(cleaned.dropLast(" remaining".count))
        }

        var totalSeconds: TimeInterval = 0
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ", "))
        for part in parts where !part.isEmpty {
            let value = Double(part.filter(\.isNumber)) ?? 0
            if part.hasSuffix("d") || part.hasSuffix("day") || part.hasSuffix("days") {
                totalSeconds += value * 86_400
            } else if part.hasSuffix("h") || part.hasSuffix("hr") || part.hasSuffix("hrs")
                || part.hasSuffix("hour") || part.hasSuffix("hours") {
                totalSeconds += value * 3_600
            } else if part.hasSuffix("m") || part.hasSuffix("min") || part.hasSuffix("mins")
                || part.hasSuffix("minute") || part.hasSuffix("minutes") {
                totalSeconds += value * 60
            }
        }
        guard totalSeconds > 0 else { return nil }
        return Date().addingTimeInterval(totalSeconds)
    }

    private func formatResetDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Resets soon" }
        let days = Int(interval / 86_400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let minutes = Int(interval.truncatingRemainder(dividingBy: 3_600) / 60)
        if days > 0 {
            return hours > 0 ? "\(days) days, \(hours) hours" : "\(days) days"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) hours, \(minutes) minutes" : "\(hours) hours"
        }
        return minutes > 0 ? "\(minutes) minutes" : "Resets soon"
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func planName(for subscriptionType: String?) -> String {
        guard let subscriptionType, !subscriptionType.isEmpty else { return "Claude" }
        return "Claude \(subscriptionType.capitalized)"
    }
}
