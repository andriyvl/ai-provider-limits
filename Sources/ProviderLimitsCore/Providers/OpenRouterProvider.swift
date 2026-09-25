import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

public struct OpenRouterProvider: AIProviderClient, Sendable {
    public let providerType: ProviderType = .openRouter
    private let session: URLSession
    private let environment: [String: String]
    private let agentDatabaseURL: URL?
    private let creditsEndpoint: URL
    private var keyEndpoint: URL {
        creditsEndpoint.deletingLastPathComponent().appendingPathComponent("key")
    }

    public init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        creditsEndpoint: URL = URL(string: "https://openrouter.ai/api/v1/credits")!,
        agentDatabaseURL: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".omp/agent/agent.db"
        )
    ) {
        self.session = session
        self.environment = environment
        self.creditsEndpoint = creditsEndpoint
        self.agentDatabaseURL = agentDatabaseURL
    }

    public func fetchUsage() async throws -> ProviderUsageSnapshot {
        let ompKey = agentDatabaseURL.flatMap { Self.loadOMPAPIKey(from: $0) }
        guard let apiKey = Self.resolveAPIKey(environment: environment, ompKey: ompKey) else {
            return ProviderUsageSnapshot(provider: .openRouter, planName: "", metrics: [], isActive: false)
        }

        async let creditsData = fetch(endpoint: creditsEndpoint, apiKey: apiKey)
        async let keyData = try? fetch(endpoint: keyEndpoint, apiKey: apiKey)
        let credits = try Self.parseCredits(data: await creditsData)
        let keyPayload = await keyData
        let key = keyPayload.flatMap { try? Self.parseKey(data: $0) }
        let keyMetric = key.flatMap { Self.keyLimitMetric(for: $0) }
        let usedPercentage =
            credits.totalCredits > 0
            ? min(100, max(0, credits.totalUsage / credits.totalCredits * 100)) : (credits.totalUsage > 0 ? 100 : 0)
        let metric = LimitMetric(
            id: "openrouter_credits",
            label: "Account Credits",
            usedPercentage: usedPercentage,
            remainingPercentage: 100 - usedPercentage,
            status: LimitStatus.evaluate(remainingPercentage: 100 - usedPercentage),
            rawLimit: credits.totalCredits,
            rawUsed: credits.totalUsage,
            unit: "USD"
        )
        var metrics = [metric]
        if let keyMetric { metrics.append(keyMetric) }

        return ProviderUsageSnapshot(
            provider: .openRouter,
            planName: "",
            metrics: metrics,
            creditsRemaining: credits.totalCredits - credits.totalUsage,
            dailySpend: key?.usageDaily
        )
    }

    public static func resolveAPIKey(environment: [String: String], ompKey: String?) -> String? {
        for candidate in [environment["OPENROUTER_API_KEY"], ompKey] {
            guard let candidate else { continue }
            let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        return nil
    }

    static func loadOMPAPIKey(from databaseURL: URL) -> String? {
        #if os(macOS) && canImport(SQLite3)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(database) }

        let query = """
            SELECT data FROM auth_credentials
            WHERE provider = 'openrouter' AND disabled_cause IS NULL
            ORDER BY id DESC LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0),
            let data = String(cString: value).data(using: .utf8),
            let credential = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return credential["key"] as? String
        #else
        return nil
        #endif
    }

    public static func parseCredits(data: Data) throws -> (totalCredits: Double, totalUsage: Double) {
        guard let response = try? JSONDecoder().decode(OpenRouterCreditsResponse.self, from: data),
            response.data.totalCredits.isFinite, response.data.totalUsage.isFinite
        else { throw ProviderClientError.invalidResponse(.openRouter, "Invalid credits payload") }
        return (response.data.totalCredits, response.data.totalUsage)
    }

    private static func parseKey(data: Data) throws -> OpenRouterKey {
        guard let response = try? JSONDecoder().decode(OpenRouterKeyResponse.self, from: data),
            response.data.usageDaily.isFinite,
            response.data.limit?.isFinite ?? true,
            response.data.limitRemaining?.isFinite ?? true
        else { throw ProviderClientError.invalidResponse(.openRouter, "Invalid key payload") }
        return response.data
    }

    private static func keyLimitMetric(for key: OpenRouterKey) -> LimitMetric? {
        guard let limit = key.limit, let remaining = key.limitRemaining else { return nil }
        let remainingAmount = min(limit, max(0, remaining))
        let usedAmount = limit - remainingAmount
        let remainingPercentage = limit > 0 ? remainingAmount / limit * 100 : 0
        let limitText = limit.formatted(.currency(code: "USD"))
        let usedText = usedAmount.formatted(.currency(code: "USD"))
        let remainingText = remainingAmount.formatted(.currency(code: "USD"))
        let resetText = key.limitReset.map { " · resets \($0)" } ?? ""

        return LimitMetric(
            id: "openrouter_key_limit",
            label: "API Key Spend Limit",
            sublabel: "\(usedText) used of \(limitText) · \(remainingText) remaining\(resetText)",
            usedPercentage: 100 - remainingPercentage,
            remainingPercentage: remainingPercentage,
            rawLimit: limit,
            rawUsed: usedAmount,
            unit: "USD"
        )
    }

    private struct OpenRouterKeyResponse: Decodable {
        let data: OpenRouterKey
    }

    private struct OpenRouterKey: Decodable {
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: String?
        let usageDaily: Double

        enum CodingKeys: String, CodingKey {
            case limit
            case limitRemaining = "limit_remaining"
            case limitReset = "limit_reset"
            case usageDaily = "usage_daily"
        }
    }


    private func fetch(endpoint: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse(.openRouter, "Missing HTTP response")
        }
        if response.statusCode == 429 { throw ProviderClientError.rateLimited(.openRouter, nil) }
        guard response.statusCode == 200 else {
            throw ProviderClientError.invalidResponse(.openRouter, "HTTP \(response.statusCode)")
        }
        return data
    }
}

private struct OpenRouterCreditsResponse: Decodable { let data: OpenRouterCredits }

private struct OpenRouterCredits: Decodable {
    let totalCredits: Double
    let totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

