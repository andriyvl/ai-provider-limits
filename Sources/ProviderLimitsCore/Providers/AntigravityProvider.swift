import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public struct AntigravityCredentials: Sendable {
    public let accessToken: String
    public let projectId: String
    public let email: String?

    public init(accessToken: String, projectId: String, email: String? = nil) {
        self.accessToken = accessToken
        self.projectId = projectId
        self.email = email
    }
}

public struct AntigravityProvider: AIProviderClient, Sendable {
    public let providerType: ProviderType = .antigravity
    private let customStoragePath: URL?
    private let customToken: String?
    private let customProjectId: String?
    private let customEndpoint: URL?

    private static let defaultEndpoint = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    )!
    private static let fallbackModelsEndpoint = URL(
        string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    )!
    private static let userAgent = "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)"

    public init(
        customStoragePath: URL? = nil,
        customToken: String? = nil,
        customProjectId: String? = nil,
        customEndpoint: URL? = nil
    ) {
        self.customStoragePath = customStoragePath
        self.customToken = customToken
        self.customProjectId = customProjectId
        self.customEndpoint = customEndpoint
    }

    public func fetchUsage() async throws -> ProviderUsageSnapshot {
        if let credentials = resolveCredentials() {
            do {
                return try await fetchLiveQuotaSummary(credentials: credentials)
            } catch let error as ProviderClientError {
                if case .rateLimited = error { throw error }
            }
        }
        let storageURL = resolveStorageURL()
        if FileManager.default.fileExists(atPath: storageURL.path),
           let data = try? Data(contentsOf: storageURL),
           let snapshot = try? parseStorage(data: data) {
            return snapshot
        }
        return ProviderUsageSnapshot.empty(for: .antigravity)
    }

    public func resolveCredentials() -> AntigravityCredentials? {
        if let customToken, let customProjectId {
            return AntigravityCredentials(accessToken: customToken, projectId: customProjectId)
        }
        #if os(macOS) && canImport(SQLite3)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            return readCredentialsFromSQLite(dbPath: dbURL.path)
        }
        #endif
        return nil
    }

    #if os(macOS) && canImport(SQLite3)
    private func readCredentialsFromSQLite(dbPath: String) -> AntigravityCredentials? {
        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(dbPointer) }

        let query = """
        SELECT data FROM auth_credentials
        WHERE (provider = 'google-antigravity' OR provider = 'antigravity')
        AND disabled_cause IS NULL
        ORDER BY id DESC LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbPointer, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) else { return nil }
        guard let data = String(cString: cString).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let token = json["access"] as? String ?? json["accessToken"] as? String
        let projectId = json["projectId"] as? String
        guard let token, !token.isEmpty, let projectId, !projectId.isEmpty else { return nil }
        return AntigravityCredentials(accessToken: token, projectId: projectId, email: json["email"] as? String)
    }
    #endif

    private func fetchLiveQuotaSummary(credentials: AntigravityCredentials) async throws -> ProviderUsageSnapshot {
        let endpoint = customEndpoint ?? Self.defaultEndpoint
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": credentials.projectId])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.antigravity, "Missing HTTP response")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.antigravity, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.antigravity, "HTTP \(httpResponse.statusCode)")
        }
        return try parseQuotaSummary(data: data)
    }

    private func resolveStorageURL() -> URL {
        if let customStoragePath { return customStoragePath }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Antigravity/app_storage.json")
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("app_storage.json")
        #endif
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
            return ProviderUsageSnapshot.empty(for: .antigravity)
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
