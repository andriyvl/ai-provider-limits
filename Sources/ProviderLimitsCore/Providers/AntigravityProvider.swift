import Foundation

public struct AntigravityCredentials: Sendable {
    public let accessToken: String
    public let projectId: String
    public let email: String?
    /// Set only when `accessToken` has expired; the provider renews it in memory before fetching.
    var renewal: AntigravityRenewal?

    public init(accessToken: String, projectId: String, email: String? = nil) {
        self.accessToken = accessToken
        self.projectId = projectId
        self.email = email
    }
}

/// What renewing an expired omp Antigravity token needs. The OAuth client comes from the local omp
/// install at runtime, so this repository never contains it.
struct AntigravityRenewal: Sendable {
    let refreshToken: String
    let clientID: String
    let clientSecret: String
}

/// Renewed Antigravity access tokens, kept in memory only. Never written back to the owning tool's store.
/// Google keeps the refresh token unchanged on renewal, so the owning tool's login stays valid.
private actor AntigravityTokenRenewer {
    static let shared = AntigravityTokenRenewer()

    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private var renewedTokens: [String: (accessToken: String, expiresAt: Date)] = [:]

    func accessToken(for renewal: AntigravityRenewal, session: URLSession) async throws -> String {
        if let cached = renewedTokens[renewal.refreshToken], cached.expiresAt > Date() {
            return cached.accessToken
        }
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: renewal.clientID),
            URLQueryItem(name: "client_secret", value: renewal.clientSecret),
            URLQueryItem(name: "refresh_token", value: renewal.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        // URLComponents leaves "+" unescaped, which form decoding would read as a space.
        request.httpBody = form.percentEncodedQuery.map { Data($0.replacingOccurrences(of: "+", with: "%2B").utf8) }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = CredentialParsing.nonempty(json["access_token"]) else {
            throw ProviderClientError.invalidResponse(.antigravity, "Token renewal failed")
        }
        let lifetime = CredentialParsing.number(json["expires_in"]) ?? 3_600
        renewedTokens[renewal.refreshToken] = (accessToken, Date().addingTimeInterval(lifetime - 300))
        return accessToken
    }
}

public struct AntigravityProvider: CredentialUsageClient, Sendable {
    public let providerType: ProviderType = .antigravity
    public let credentialResolver: CredentialResolver
    private let session: URLSession

    private static let cloudCodeBaseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    private static let dailyCloudCodeBaseURL = URL(string: "https://daily-cloudcode-pa.googleapis.com")!
    private static let nativeUserAgent = "antigravity/2.5.5 darwin/arm64"
    private static let ompUserAgent = "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)"

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
        switch candidate.payload {
        case let .antigravity(credentials):
            return try await fetchOMPUsage(credentials: credentials)
        case let .nativeAntigravity(nativeCreds):
            return try await fetchNativeUsage(credentials: nativeCreds)
        default:
            throw ProviderClientError.invalidResponse(.antigravity, "Unsupported credential payload for Antigravity")
        }
    }

    private func fetchOMPUsage(credentials: AntigravityCredentials) async throws -> ProviderUsageSnapshot {
        var accessToken = credentials.accessToken
        if let renewal = credentials.renewal {
            accessToken = try await AntigravityTokenRenewer.shared.accessToken(for: renewal, session: session)
        }
        let quotaURL = Self.dailyCloudCodeBaseURL.appendingPathComponent("v1internal:retrieveUserQuotaSummary")
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.ompUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": credentials.projectId])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.antigravity, "Missing HTTP response")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.antigravity, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.antigravity, "HTTP \(httpResponse.statusCode)")
        }
        return try parseLiveQuotaSummary(data: data)
    }

    private func fetchNativeUsage(credentials: NativeAntigravityCredentials) async throws -> ProviderUsageSnapshot {
        let project = try await loadNativeCodeAssistProject(credentials: credentials)
        guard !project.isEmpty else {
            throw ProviderClientError.invalidResponse(.antigravity, "Missing project from loadCodeAssist")
        }

        let quotaBase = credentials.isGCPTOS ? Self.cloudCodeBaseURL : Self.dailyCloudCodeBaseURL
        let quotaURL = quotaBase.appendingPathComponent("v1internal:retrieveUserQuotaSummary")
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.nativeUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": project])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.antigravity, "Missing HTTP response")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.antigravity, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.antigravity, "HTTP \(httpResponse.statusCode)")
        }
        return try parseLiveQuotaSummary(data: data)
    }

    private func loadNativeCodeAssistProject(credentials: NativeAntigravityCredentials) async throws -> String {
        let loadURL = Self.cloudCodeBaseURL.appendingPathComponent("v1internal:loadCodeAssist")
        var request = URLRequest(url: loadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.nativeUserAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "metadata": [
                "ide_type": "ANTIGRAVITY",
                "ide_name": "antigravity",
                "ide_version": "2.5.5"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.antigravity, "Missing HTTP response from loadCodeAssist")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.antigravity, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.antigravity, "loadCodeAssist HTTP \(httpResponse.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidResponse(.antigravity, "Invalid loadCodeAssist response JSON")
        }

        let project = CredentialParsing.nonempty(json["cloudaicompanion_project"])
            ?? CredentialParsing.nonempty(json["cloudaicompanionProject"])
        guard let project else {
            throw ProviderClientError.invalidResponse(.antigravity, "Empty cloudaicompanion_project")
        }
        return project
    }

    private func parseLiveQuotaSummary(data: Data) throws -> ProviderUsageSnapshot {
        let snapshot = try parseQuotaSummary(data: data)
        guard !snapshot.metrics.isEmpty || snapshot.creditsRemaining != nil else {
            throw ProviderClientError.invalidResponse(.antigravity, "Empty quota response")
        }
        return snapshot
    }

    public func parseStorage(data: Data) throws -> ProviderUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderUsageSnapshot.empty(for: .antigravity)
        }
        if json["groups"] != nil { return try parseQuotaSummary(data: data) }
        if json["models"] != nil { return try parseAvailableModels(data: data) }

        var metrics: [LimitMetric] = []
        if let gemini = json["gemini_models"] as? [String: Any] {
            metrics.append(contentsOf: parseLegacyGeminiMetrics(gemini))
        }
        if let otherModels = json["claude_and_gpt_models"] as? [String: Any] {
            metrics.append(contentsOf: parseLegacyOtherMetrics(otherModels))
        }
        return ProviderUsageSnapshot(
            provider: .antigravity,
            planName: json["plan"] as? String ?? "Google AI Pro",
            metrics: metrics,
            creditsRemaining: json["credits_remaining"] as? Double ?? 0.0,
            isCreditOverageEnabled: json["credit_overages_enabled"] as? Bool ?? false
        )
    }

    private func parseLegacyGeminiMetrics(_ gemini: [String: Any]) -> [LimitMetric] {
        let weekly = gemini["weekly_limit_remaining"] as? Double ?? 100.0
        let fiveHour = gemini["five_hour_limit_remaining"] as? Double ?? 100.0
        let weeklyDesc = gemini["weekly_resets_in"] as? String
        let fiveHourDesc = gemini["five_hour_resets_in"] as? String
        return [
            LimitMetric(
                id: "gemini_weekly",
                label: "Gemini Models · Weekly Limit",
                usedPercentage: max(0.0, 100.0 - weekly),
                remainingPercentage: min(100.0, max(0.0, weekly)),
                resetsAt: parseRelativeDurationDate(weeklyDesc),
                resetInDescription: weeklyDesc
            ),
            LimitMetric(
                id: "gemini_5hour",
                label: "Gemini Models · 5-Hour Limit",
                usedPercentage: max(0.0, 100.0 - fiveHour),
                remainingPercentage: min(100.0, max(0.0, fiveHour)),
                resetsAt: parseRelativeDurationDate(fiveHourDesc),
                resetInDescription: fiveHourDesc
            )
        ]
    }

    private func parseLegacyOtherMetrics(_ other: [String: Any]) -> [LimitMetric] {
        let weekly = other["weekly_limit_remaining"] as? Double ?? 100.0
        let fiveHour = other["five_hour_limit_remaining"] as? Double ?? 100.0
        return [
            LimitMetric(
                id: "claude_gpt_weekly",
                label: "Claude & GPT · Weekly Limit",
                usedPercentage: max(0.0, 100.0 - weekly),
                remainingPercentage: min(100.0, max(0.0, weekly))
            ),
            LimitMetric(
                id: "claude_gpt_5hour",
                label: "Claude & GPT · 5-Hour Limit",
                usedPercentage: max(0.0, 100.0 - fiveHour),
                remainingPercentage: min(100.0, max(0.0, fiveHour))
            )
        ]
    }

    public func parseQuotaSummary(data: Data) throws -> ProviderUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else {
            throw ProviderClientError.invalidResponse(.antigravity, "Missing or invalid groups in quota summary")
        }
        let metrics = groups.flatMap { parseQuotaGroup($0) }
        return ProviderUsageSnapshot(
            provider: .antigravity,
            planName: "Google AI Pro",
            metrics: metrics
        )
    }

    private func parseQuotaGroup(_ group: [String: Any]) -> [LimitMetric] {
        let name = group["displayName"] as? String ?? ""
        let prefix = name.localizedCaseInsensitiveContains("Gemini") ? "Gemini Models" : "Claude & GPT"
        let buckets = group["buckets"] as? [[String: Any]] ?? []
        return buckets.compactMap { parseBucket($0, prefix: prefix) }
    }

    private func parseBucket(_ bucket: [String: Any], prefix: String) -> LimitMetric {
        let bucketId = bucket["bucketId"] as? String ?? ""
        let frac = bucket["remainingFraction"] as? Double ?? 1.0
        let resetDate = parseResetDate(bucket["resetTime"] as? String)
        let remain = min(100.0, max(0.0, frac * 100.0))
        let isWeekly = bucketId.contains("weekly")
        let desc = remain < 100.0 || bucket["description"] != nil
            ? formatResetDescription(bucket["description"] as? String, resetDate: resetDate)
            : nil

        return LimitMetric(
            id: isWeekly
                ? (prefix.contains("Gemini") ? "gemini_weekly" : "claude_gpt_weekly")
                : (prefix.contains("Gemini") ? "gemini_5hour" : "claude_gpt_5hour"),
            label: "\(prefix) · \(isWeekly ? "Weekly Limit" : "5-Hour Limit")",
            usedPercentage: max(0.0, 100.0 - remain),
            remainingPercentage: remain,
            resetsAt: resetDate,
            resetInDescription: desc,
            status: LimitStatus.evaluate(remainingPercentage: remain)
        )
    }

    public func parseAvailableModels(data: Data) throws -> ProviderUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: [String: Any]] else {
            return ProviderUsageSnapshot.empty(for: .antigravity)
        }
        var metrics: [LimitMetric] = []
        for (modelId, info) in models {
            guard let quota = info["quotaInfo"] as? [String: Any],
                  let frac = quota["remainingFraction"] as? Double else { continue }
            let remain = min(100.0, max(0.0, frac * 100.0))
            let resetDate = parseResetDate(quota["resetTime"] as? String)
            let isGemini = modelId.localizedCaseInsensitiveContains("gemini")
            metrics.append(LimitMetric(
                id: isGemini ? "gemini_weekly" : "claude_gpt_weekly",
                label: "\(isGemini ? "Gemini Models" : "Claude & GPT") · Weekly Limit",
                usedPercentage: max(0.0, 100.0 - remain),
                remainingPercentage: remain,
                resetsAt: resetDate,
                resetInDescription: formatResetDescription(nil, resetDate: resetDate)
            ))
        }
        return ProviderUsageSnapshot(provider: .antigravity, planName: "Google AI Pro", metrics: metrics)
    }

    private func parseResetDate(_ dateStr: String?) -> Date? {
        guard let dateStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
    }

    private func formatResetDescription(_ description: String?, resetDate: Date?) -> String? {
        if let desc = description {
            if let range = desc.range(of: "refresh in ", options: .caseInsensitive) {
                return String(desc[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
        }
        guard let resetDate else { return description }
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

    private func parseRelativeDurationDate(_ desc: String?) -> Date? {
        guard let desc else { return nil }
        var cleaned = desc.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["resets in ", "refresh in ", "in "] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        if cleaned.hasSuffix(" remaining") {
            cleaned = String(cleaned.dropLast(" remaining".count))
        }

        var totalSeconds: TimeInterval = 0
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ", "))
        for part in parts where !part.isEmpty {
            if part.hasSuffix("d") || part.hasSuffix("day") || part.hasSuffix("days") {
                let digits = part.filter { $0.isNumber }
                if let val = Double(digits) { totalSeconds += val * 86400 }
            } else if part.hasSuffix("h") || part.hasSuffix("hr") || part.hasSuffix("hrs")
                || part.hasSuffix("hour") || part.hasSuffix("hours") {
                let digits = part.filter { $0.isNumber }
                if let val = Double(digits) { totalSeconds += val * 3600 }
            } else if part.hasSuffix("m") || part.hasSuffix("min") || part.hasSuffix("mins")
                || part.hasSuffix("minute") || part.hasSuffix("minutes") {
                let digits = part.filter { $0.isNumber }
                if let val = Double(digits) { totalSeconds += val * 60 }
            }
        }
        guard totalSeconds > 0 else { return nil }
        return Date().addingTimeInterval(totalSeconds)
    }
}
