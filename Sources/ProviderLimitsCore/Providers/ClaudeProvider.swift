import Foundation

public struct ClaudeCredentials: Sendable {
    public let accessToken: String
    public let subscriptionType: String?

    public init(accessToken: String, subscriptionType: String? = nil) {
        self.accessToken = accessToken
        self.subscriptionType = subscriptionType
    }
}

public struct ClaudeProvider: CredentialUsageClient, Sendable {
    public let providerType: ProviderType = .claude
    public let credentialResolver: CredentialResolver
    private let session: URLSession
    private let endpoint: URL

    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(
        resolver: CredentialResolver = CredentialResolver(),
        session: URLSession = .shared,
        endpoint: URL? = nil
    ) {
        self.credentialResolver = resolver
        self.session = session
        self.endpoint = endpoint ?? Self.usageEndpoint
    }

    public func fetchUsage(selection: CredentialSelection = .automatic) async throws -> ProviderUsageSnapshot {
        try await fetchSelectedUsage(selection: selection)
    }

    func fetchUsage(using candidate: CredentialCandidate) async throws -> ProviderUsageSnapshot {
        guard case let .claude(credentials) = candidate.payload, !credentials.accessToken.isEmpty else {
            throw ProviderClientError.missingCredentials(.claude)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
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

        let usageJSON = (json["usage"] as? [String: Any]) ?? json
        let resolvedPlanName = await fetchProfilePlanName(accessToken: credentials.accessToken)
            ?? planName(for: credentials.subscriptionType)
        let snapshot = try parseUsagePayload(json: usageJSON, planName: resolvedPlanName)
        guard !snapshot.metrics.isEmpty || snapshot.creditsRemaining != nil else {
            throw ProviderClientError.invalidResponse(.claude, "Empty usage payload")
        }
        return snapshot
    }

    /// Best-effort: the usage payload carries no tier and omp logins store no subscription type,
    /// so the profile endpoint is the only source for "Max 5x"-style plan names.
    private func fetchProfilePlanName(accessToken: String) async -> String? {
        var request = URLRequest(url: endpoint.deletingLastPathComponent().appendingPathComponent("profile"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Self.parseProfilePlanName(json: json)
    }

    public static func parseProfilePlanName(json: [String: Any]) -> String? {
        let organization = json["organization"] as? [String: Any]
        if let tier = organization?["rate_limit_tier"] as? String,
           let match = tier.firstMatch(of: /max_(\d+)x/) {
            return "Max \(match.1)x"
        }
        switch organization?["organization_type"] as? String {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }

    public static func parseCredentials(data: Data) -> ClaudeCredentials? {
        CredentialParsing.parseClaudeCredentials(data: data)
    }

    public func parseUsagePayload(
        json: [String: Any],
        planName: String? = nil
    ) throws -> ProviderUsageSnapshot {
        let windows = [
            ("five_hour", "claude_5hour", "Claude Models · 5-Hour Limit"),
            ("seven_day", "claude_weekly", "Claude Models · Weekly Limit"),
            ("seven_day_sonnet", "claude_sonnet", "Sonnet · Weekly Limit"),
            ("seven_day_opus", "claude_opus", "Opus · Weekly Limit")
        ]
        var metrics = windows.compactMap { window -> LimitMetric? in
            let (key, id, label) = window
            guard let usage = json[key] as? [String: Any] else { return nil }
            return parseUsageMetric(usage, id: id, label: label)
        }
        metrics += parseScopedWeeklyMetrics(json["limits"], excluding: metrics)
        let extraUsage = json["extra_usage"] as? [String: Any]
        let balance = numericValue(extraUsage?["balance"])

        return ProviderUsageSnapshot(
            provider: .claude,
            planName: planName ?? json["plan_name"] as? String ?? "",
            metrics: metrics,
            creditsRemaining: balance,
            isActive: !metrics.isEmpty
        )
    }

    /// Model- or surface-specific weekly caps (e.g. Fable) appear only in the `limits` array.
    private func parseScopedWeeklyMetrics(_ value: Any?, excluding existing: [LimitMetric]) -> [LimitMetric] {
        let coveredClasses = Set(existing.compactMap { $0.modelClass?.lowercased() })
        let limits = value as? [[String: Any]] ?? []
        return limits.compactMap { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any] else { return nil }
            let scopeName = (scope["model"] as? [String: Any])?["display_name"] as? String
                ?? (scope["surface"] as? [String: Any])?["display_name"] as? String
            guard let scopeName, !scopeName.isEmpty,
                  !coveredClasses.contains(scopeName.lowercased()) else { return nil }
            var usage: [String: Any] = [:]
            usage["utilization"] = limit["percent"]
            usage["resets_at"] = limit["resets_at"]
            let slug = scopeName.lowercased().replacingOccurrences(of: " ", with: "_")
            return parseUsageMetric(usage, id: "claude_weekly_\(slug)", label: "\(scopeName) · Weekly Limit")
        }
    }

    private func parseUsageMetric(
        _ usage: [String: Any],
        id: String,
        label: String
    ) -> LimitMetric {
        // The OAuth usage endpoint reports utilization as a percent (0–100); 1.0 means 1% used.
        let usedPercentage = numericValue(usage["utilization"]) ?? 0.0
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

    private func planName(for subscriptionType: String?) -> String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        return subscriptionType.capitalized
    }
}
