import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

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


public struct CursorProvider: AIProviderClient, Sendable {
    public let providerType: ProviderType = .cursor
    private let configURL: URL?
    private let customToken: String?
    private let customUserId: String?

    private static let summaryBaseURL = "https://cursor.com/api/usage-summary"
    private static let creditGrantsURL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance"
    private static let sandUsageURL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"

    public init(
        configURL: URL? = nil,
        customToken: String? = nil,
        customUserId: String? = nil
    ) {
        self.configURL = configURL
        self.customToken = customToken
        self.customUserId = customUserId
    }

    public func fetchUsage() async throws -> ProviderUsageSnapshot {
        if let credentials = resolveCredentials() {
            do {
                return try await fetchLiveUsage(credentials: credentials)
            } catch let error as ProviderClientError {
                if case .rateLimited = error { throw error }
            }
        }

        let fileURL = resolveConfigURL()
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let snapshot = try? parseUsagePayload(data: data) {
            return snapshot
        }

        return ProviderUsageSnapshot.empty(for: .cursor)
    }

    public func resolveCredentials() -> CursorCredentials? {
        if let customToken, let customUserId {
            return CursorCredentials(accessToken: customToken, userId: customUserId)
        }

        #if os(macOS) && canImport(SQLite3)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let vscdbURL = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        if FileManager.default.fileExists(atPath: vscdbURL.path),
           let creds = readCredentialsFromVscdb(dbPath: vscdbURL.path) {
            return creds
        }

        let agentDbURL = home.appendingPathComponent(".omp/agent/agent.db")
        if FileManager.default.fileExists(atPath: agentDbURL.path),
           let creds = readCredentialsFromAgentDb(dbPath: agentDbURL.path) {
            return creds
        }
        #endif

        return nil
    }

    #if os(macOS) && canImport(SQLite3)
    private func readCredentialsFromVscdb(dbPath: String) -> CursorCredentials? {
        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(dbPointer) }

        var token: String?
        var userId: String?
        var membership: String?

        let query = """
        SELECT key, value FROM ItemTable
        WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/stripeMembershipAuthId', 'cursorAuth/stripeMembershipType')
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbPointer, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(stmt, 0), let valC = sqlite3_column_text(stmt, 1) else { continue }
            let key = String(cString: keyC)
            let val = String(cString: valC)
            if key == "cursorAuth/accessToken" { token = val }
            if key == "cursorAuth/stripeMembershipAuthId" { userId = val }
            if key == "cursorAuth/stripeMembershipType" { membership = val }
        }

        guard let token, !token.isEmpty, let userId, !userId.isEmpty else { return nil }
        return CursorCredentials(accessToken: token, userId: userId, membershipType: membership)
    }

    private func readCredentialsFromAgentDb(dbPath: String) -> CursorCredentials? {
        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(dbPointer) }

        let query = """
        SELECT data FROM auth_credentials
        WHERE provider = 'cursor' AND disabled_cause IS NULL
        ORDER BY id DESC LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbPointer, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) else { return nil }
        guard let data = String(cString: cString).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access"] as? String, !token.isEmpty else { return nil }

        let userId = parseUserIdFromJWT(token) ?? "user"
        return CursorCredentials(accessToken: token, userId: userId)
    }

    func parseUserIdFromJWT(_ jwt: String) -> String? {
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
    #endif

    private func fetchLiveUsage(credentials: CursorCredentials) async throws -> ProviderUsageSnapshot {
        guard let url = URL(string: "\(Self.summaryBaseURL)?user=\(credentials.userId)") else {
            throw ProviderClientError.invalidResponse(.cursor, "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let cookieVal = "\(credentials.userId)%3A%3A\(credentials.accessToken)"
        request.setValue("WorkosCursorSessionToken=\(cookieVal)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        async let creditsTask = fetchCreditGrantsBalance(token: credentials.accessToken)
        async let sandUsageTask = fetchSandUsageStatus(token: credentials.accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
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

        return try parseLiveUsageJSON(
            json: json,
            credentials: credentials,
            creditsRemaining: creditsRemaining,
            sandUsage: sandUsage
        )
    }

    private func fetchCreditGrantsBalance(token: String) async -> Double? {
        guard let url = URL(string: Self.creditGrantsURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
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
        guard let url = URL(string: Self.sandUsageURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
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
    private func resolveConfigURL() -> URL {
        if let configURL { return configURL }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cursor/cli-config.json")
        #else
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("cursor_config.json")
        #endif
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
