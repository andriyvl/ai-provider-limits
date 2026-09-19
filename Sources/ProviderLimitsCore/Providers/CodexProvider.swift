import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public struct CodexCredentials: Sendable {
    public let accessToken: String
    public let accountId: String?

    public init(accessToken: String, accountId: String? = nil) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

public struct CodexProvider: AIProviderClient, Sendable {
    public let providerType: ProviderType = .codex
    private let authFileURL: URL?
    private let customToken: String?
    private let customAccountId: String?

    private static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(
        authFileURL: URL? = nil,
        customToken: String? = nil,
        customAccountId: String? = nil
    ) {
        self.authFileURL = authFileURL
        self.customToken = customToken
        self.customAccountId = customAccountId
    }

    public func fetchUsage() async throws -> ProviderUsageSnapshot {
        let candidates = resolveAllCandidateCredentials()
        var lastError: Error?

        for credentials in candidates {
            do {
                return try await fetchLiveUsage(credentials: credentials)
            } catch let error as ProviderClientError {
                if case .rateLimited = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }

        let authURL = resolveAuthURL()
        if FileManager.default.fileExists(atPath: authURL.path),
           let authData = try? Data(contentsOf: authURL),
           let snapshot = try? parseLocalAuth(data: authData),
           !snapshot.metrics.isEmpty {
            return snapshot
        }

        if let lastError {
            throw lastError
        }

        if candidates.isEmpty {
            throw ProviderClientError.missingCredentials(.codex)
        }

        return ProviderUsageSnapshot(
            provider: .codex,
            planName: "ChatGPT",
            metrics: [],
            isActive: false
        )
    }

    public func resolveCredentials() -> CodexCredentials? {
        resolveAllCandidateCredentials().first
    }

    public func resolveAllCandidateCredentials() -> [CodexCredentials] {
        var candidates: [CodexCredentials] = []

        if let customToken {
            candidates.append(CodexCredentials(accessToken: customToken, accountId: customAccountId))
        }

        let authURL = resolveAuthURL()
        if let data = try? Data(contentsOf: authURL),
           let credentials = parseCredentials(data: data) {
            candidates.append(credentials)
        }

        #if os(macOS) && canImport(SQLite3)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbURL = home.appendingPathComponent(".omp/agent/agent.db")
        if FileManager.default.fileExists(atPath: dbURL.path) {
            candidates.append(contentsOf: readCredentialsFromSQLite(dbPath: dbURL.path))
        }
        #endif

        return prioritizeCredentials(candidates)
    }

    private func prioritizeCredentials(_ candidates: [CodexCredentials]) -> [CodexCredentials] {
        var seenTokens = Set<String>()
        var unique: [CodexCredentials] = []
        for cred in candidates {
            if seenTokens.insert(cred.accessToken).inserted {
                unique.append(cred)
            }
        }

        return unique.sorted { lhs, rhs in
            let leftExp = tokenExpiration(lhs.accessToken) ?? 0
            let rightExp = tokenExpiration(rhs.accessToken) ?? 0
            return leftExp > rightExp
        }
    }

    private func tokenExpiration(_ token: String) -> TimeInterval? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let exp = json["exp"] as? Double {
            return exp
        }
        if let exp = json["exp"] as? Int {
            return Double(exp)
        }
        return nil
    }

    public func parseCredentials(data: Data) -> CodexCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tokens = json["tokens"] as? [String: Any]
        let accessToken = tokens?["access_token"] as? String
            ?? tokens?["accessToken"] as? String
            ?? json["access_token"] as? String
            ?? json["accessToken"] as? String
        guard let accessToken, !accessToken.isEmpty else { return nil }

        let accountId = tokens?["account_id"] as? String
            ?? tokens?["accountId"] as? String
            ?? json["account_id"] as? String
            ?? json["accountId"] as? String
        return CodexCredentials(accessToken: accessToken, accountId: accountId)
    }

    #if os(macOS) && canImport(SQLite3)
    private func readCredentialsFromSQLite(dbPath: String) -> [CodexCredentials] {
        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(dbPointer) }

        let query = """
        SELECT data FROM auth_credentials
        WHERE provider = 'openai-codex' AND disabled_cause IS NULL
        ORDER BY id DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbPointer, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [CodexCredentials] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0),
                  let data = String(cString: cString).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access"] as? String, !token.isEmpty else {
                continue
            }
            let accountId = json["accountId"] as? String
                ?? (json["account"] as? [String: Any])?["id"] as? String
            results.append(CodexCredentials(accessToken: token, accountId: accountId))
        }
        return results
    }
    #endif

    private func fetchLiveUsage(credentials: CodexCredentials) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.codex, "Missing HTTP response")
        }
        if httpResponse.statusCode == 429 {
            throw ProviderClientError.rateLimited(.codex, nil)
        }
        guard httpResponse.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.codex, "HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidResponse(.codex, "Invalid JSON")
        }

        return try parseUsagePayload(json: json)
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

    private func resolveAuthURL() -> URL {
        if let authFileURL {
            return authFileURL
        }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/auth.json")
        #else
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("codex_auth.json")
        #endif
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
