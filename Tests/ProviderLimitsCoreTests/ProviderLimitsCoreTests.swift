import Testing
import Foundation
@testable import ProviderLimitsCore

@Suite("Provider Limits Core Tests")
struct ProviderLimitsCoreTests {

    @Test("Evaluate limit status thresholds")
    func testLimitStatusEvaluation() {
        #expect(LimitStatus.evaluate(remainingPercentage: 80.0) == .normal)
        #expect(LimitStatus.evaluate(remainingPercentage: 35.0) == .warning)
        #expect(LimitStatus.evaluate(remainingPercentage: 10.0) == .critical)
        #expect(LimitStatus.evaluate(remainingPercentage: 0.0) == .depleted)
    }

    @Test("Subscription badge uses requested day thresholds")
    func testSubscriptionStatusThresholds() {
        let baseDate = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProviderUsageSnapshot(
            provider: .cursor,
            planName: "Cursor Pro",
            fetchedAt: baseDate,
            metrics: [],
            subscriptionEndsAt: baseDate.addingTimeInterval(11 * 86_400)
        )

        #expect(snapshot.subscriptionDaysRemaining(relativeTo: baseDate) == 11)
        #expect(snapshot.subscriptionStatus(relativeTo: baseDate) == .healthy)
        #expect(snapshot.subscriptionStatus(relativeTo: baseDate.addingTimeInterval(-3 * 86_400 - 1)) == .healthy)
        #expect(snapshot.subscriptionStatus(relativeTo: baseDate.addingTimeInterval(2 * 86_400)) == .warning)
        #expect(snapshot.subscriptionStatus(relativeTo: baseDate.addingTimeInterval(8 * 86_400)) == .critical)
    }

    @Test("Antigravity quota summary parser matches live Google response")
    func testAntigravityQuotaSummaryParser() throws {
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
                  "description": "You have used some of your weekly limit, it will fully refresh in 6 days.",
                  "remainingFraction": 0.73
                },
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "resetTime": "2026-08-19T18:11:46Z",
                  "description": "You have used some of your 5-hour limit, it will fully refresh in 4 hours.",
                  "remainingFraction": 0.90
                }
              ]
            }
          ]
        }
        """

        let provider = AntigravityProvider()
        let snapshot = try provider.parseQuotaSummary(data: Data(json.utf8))

        #expect(snapshot.provider == .antigravity)
        #expect(snapshot.planName == "Google AI Pro")
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].label == "Gemini Models · Weekly Limit")
        #expect(snapshot.metrics[0].remainingPercentage == 73.0)
        #expect(snapshot.metrics[0].resetInDescription == "6 days")
        #expect(snapshot.metrics[1].label == "Gemini Models · 5-Hour Limit")
        #expect(snapshot.metrics[1].remainingPercentage == 90.0)
        #expect(snapshot.metrics[1].resetInDescription == "4 hours")
    }

    @Test("Antigravity storage parser handles legacy format")
    func testAntigravityLegacyParser() throws {
        let json = """
        {
            "plan": "Google AI Pro",
            "credits_remaining": 500.0,
            "credit_overages_enabled": true,
            "gemini_models": {
                "weekly_limit_remaining": 82.5,
                "weekly_resets_in": "5 days",
                "five_hour_limit_remaining": 45.0,
                "five_hour_resets_in": "1 hour"
            }
        }
        """

        let provider = AntigravityProvider()
        let snapshot = try provider.parseStorage(data: Data(json.utf8))

        #expect(snapshot.provider == .antigravity)
        #expect(snapshot.planName == "Google AI Pro")
        #expect(snapshot.creditsRemaining == 500.0)
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].remainingPercentage == 82.5)
        #expect(snapshot.metrics[1].remainingPercentage == 45.0)
    }

    @Test("Codex parser maps primary window to 5-hour and secondary to weekly")
    func testCodexRateLimitWindows() throws {
        let json: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 13,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 15449,
                    "reset_at": 1_787_764_193
                ],
                "secondary_window": [
                    "used_percent": 2,
                    "limit_window_seconds": 604_800,
                    "reset_after_seconds": 533_114,
                    "reset_at": 1_788_281_859
                ]
            ],
            "credits": [
                "balance": "0"
            ]
        ]

        let provider = CodexProvider()
        let snapshot = try provider.parseUsagePayload(json: json)

        #expect(snapshot.provider == .codex)
        #expect(snapshot.planName == "ChatGPT Plus / Codex")
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].id == "codex_5hour")
        #expect(snapshot.metrics[0].label == "GPT Models · 5-Hour Limit")
        #expect(snapshot.metrics[0].remainingPercentage == 87.0)
        #expect(snapshot.metrics[1].id == "codex_weekly")
        #expect(snapshot.metrics[1].label == "GPT Models · Weekly Limit")
        #expect(snapshot.metrics[1].remainingPercentage == 98.0)
        #expect(snapshot.creditsRemaining == 0.0)
    }

    @Test("Codex reads OAuth credentials from local auth file")
    func testCodexCredentialsParser() throws {
        let data = Data("""
        {
            "tokens": {
                "access_token": "codex-token",
                "account_id": "account-123"
            }
        }
        """.utf8)

        let credentials = try #require(CodexProvider().parseCredentials(data: data))
        #expect(credentials.accessToken == "codex-token")
        #expect(credentials.accountId == "account-123")
    }

    @Test("Codex parser matches screenshot data")
    func testCodexParser() throws {
        let json: [String: Any] = [
            "plan_type": "ChatGPT Plus / Codex",
            "credits_remaining": 0.0,
            "weekly_limit": [
                "percentage_remaining": 1.0,
                "resets_at": "Resets Aug 20, 2026 9:49 AM"
            ]
        ]

        let provider = CodexProvider()
        let snapshot = try provider.parseUsagePayload(json: json)

        #expect(snapshot.provider == .codex)
        #expect(snapshot.planName == "ChatGPT Plus / Codex")
        #expect(snapshot.metrics.count == 1)
        #expect(snapshot.metrics[0].label == "GPT Models · Weekly Limit")
        #expect(snapshot.metrics[0].remainingPercentage == 1.0)
    }

    @Test("Claude parser calculates 5h and 7d metrics")
    func testClaudeParser() throws {
        let json: [String: Any] = [
            "plan_name": "Claude Pro",
            "five_hour": ["utilization": 0.35, "resets_in": "3h 45m"],
            "seven_day": ["utilization": 0.85, "resets_in": "2 days"]
        ]

        let provider = ClaudeProvider()
        let snapshot = try provider.parseUsagePayload(json: json)

        #expect(snapshot.provider == .claude)
        #expect(snapshot.planName == "Claude Pro")
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].remainingPercentage == 65.0)
        #expect(snapshot.metrics[1].remainingPercentage == 15.0)
    }

    @Test("Claude reads OAuth credentials from local credentials file")
    func testClaudeCredentialsParser() throws {
        let data = Data("""
        {
            "claudeAiOauth": {
                "accessToken": "claude-token",
                "subscriptionType": "max"
            }
        }
        """.utf8)

        let credentials = try #require(ClaudeProvider().parseCredentials(data: data))
        #expect(credentials.accessToken == "claude-token")
        #expect(credentials.subscriptionType == "max")
    }

    @Test("Claude parser handles live reset timestamps and Opus limits")
    func testClaudeLiveUsageParser() throws {
        let resetDate = "2026-09-10T12:00:00Z"
        let json: [String: Any] = [
            "five_hour": ["utilization": 35.0, "resets_at": resetDate],
            "seven_day_opus": ["utilization": 10.0, "resets_at": resetDate]
        ]

        let snapshot = try ClaudeProvider().parseUsagePayload(json: json, planName: "Claude Max")
        #expect(snapshot.planName == "Claude Max")
        #expect(snapshot.metrics.map(\.id) == ["claude_5hour", "claude_opus"])
        #expect(snapshot.metrics[0].remainingPercentage == 65.0)
        #expect(snapshot.metrics[0].resetsAt != nil)
        #expect(snapshot.metrics[1].remainingPercentage == 90.0)
    }

    @Test("Cursor parser matches screenshot models")
    func testCursorParser() throws {
        let json = """
        {
            "plan": "Included in Pro",
            "on_demand_spend": 0.0,
            "cursor_models": {
                "used_percentage": 48.0,
                "label": "Cursor Models"
            }
        }
        """

        let provider = CursorProvider()
        let snapshot = try provider.parseUsagePayload(data: Data(json.utf8))

        #expect(snapshot.provider == .cursor)
        #expect(snapshot.creditsRemaining == nil)
        #expect(snapshot.metrics.count == 1)
        #expect(snapshot.metrics[0].usedPercentage == 48.0)
        #expect(snapshot.metrics[0].remainingPercentage == 52.0)
    }

    @Test("Cursor parser correctly parses explicit credits balance")
    func testCursorParserWithCredits() throws {
        let json = """
        {
            "plan": "Included in Pro",
            "credits_remaining": 2.0,
            "cursor_models": {
                "used_percentage": 48.0,
                "label": "Cursor Models"
            }
        }
        """

        let provider = CursorProvider()
        let snapshot = try provider.parseUsagePayload(data: Data(json.utf8))

        #expect(snapshot.provider == .cursor)
        #expect(snapshot.creditsRemaining == 2.0)
    }

    @Test("Cursor live parser calculates metrics and credits")
    func testCursorLiveUsageParser() throws {
        let json: [String: Any] = [
            "individualUsage": [
                "plan": [
                    "autoPercentUsed": 48.0,
                    "apiPercentUsed": 100.0
                ]
            ]
        ]

        let creds = CursorCredentials(accessToken: "tok", userId: "usr", membershipType: "pro")
        let provider = CursorProvider()
        let snapshot = try provider.parseLiveUsageJSON(json: json, credentials: creds, creditsRemaining: 0.93)

        #expect(snapshot.provider == .cursor)
        #expect(snapshot.planName == "Included in Pro")
        #expect(snapshot.creditsRemaining == 0.93)
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].remainingPercentage == 52.0)
        #expect(snapshot.metrics[1].remainingPercentage == 0.0)
    }

    @Test("Cursor live parser parses Grok Bot weekly usage matching screenshot")
    func testCursorLiveUsageParserWithGrokBot() throws {
        let json: [String: Any] = [
            "individualUsage": [
                "plan": [
                    "autoPercentUsed": 98.35,
                    "apiPercentUsed": 100.0
                ]
            ]
        ]

        let sandJson: [String: Any] = [
            "usagePercent": 6.0,
            "nextResetTimestampUtc": "2026-09-10T10:44:57.000Z",
            "hasNonZeroIncludedLimit": true
        ]

        let provider = CursorProvider()
        let sandStatus = provider.parseSandUsageStatus(json: sandJson)
        #expect(sandStatus != nil)
        #expect(sandStatus?.usedPercentage == 6.0)

        let creds = CursorCredentials(accessToken: "tok", userId: "usr", membershipType: "pro")
        let snapshot = try provider.parseLiveUsageJSON(
            json: json,
            credentials: creds,
            creditsRemaining: 0.0,
            sandUsage: sandStatus
        )

        #expect(snapshot.provider == .cursor)
        #expect(snapshot.metrics.count == 3)
        let grokMetric = try #require(snapshot.metrics.first { $0.id == "grok_bot" })
        #expect(grokMetric.label == "Grok Bot · Weekly")
        #expect(grokMetric.modelClass == "Grok Bot")
        #expect(grokMetric.usedPercentage == 6.0)
        #expect(grokMetric.remainingPercentage == 94.0)
        #expect(grokMetric.shortDialLabel == "Grok")
        #expect(MetricRowView.shortWindowName(from: grokMetric.label) == "Weekly")
        #expect(MetricRowView.formatModelLine(for: grokMetric) == "Grok Bot")
    }

    @Test("Cursor sand usage parser handles multiple formats and zero limit")
    func testCursorSandUsageParserFormats() {
        let provider = CursorProvider()

        let snakeCase: [String: Any] = [
            "usage_percent": 6.0,
            "next_reset_timestamp_utc": "2026-09-10T10:44:57Z"
        ]
        let parsedSnake = provider.parseSandUsageStatus(json: snakeCase)
        #expect(parsedSnake?.usedPercentage == 6.0)
        #expect(parsedSnake?.resetsAt != nil)

        let dictTimestamp: [String: Any] = [
            "usagePercent": 12.5,
            "nextResetTimestampUtc": [
                "seconds": 1788960297,
                "nanos": 0
            ]
        ]
        let parsedDict = provider.parseSandUsageStatus(json: dictTimestamp)
        #expect(parsedDict?.usedPercentage == 12.5)
        #expect(parsedDict?.resetsAt != nil)

        let disabled: [String: Any] = [
            "includedLimitZero": true,
            "usagePercent": 0.0
        ]
        #expect(provider.parseSandUsageStatus(json: disabled) == nil)
    }

    @Test("Cursor parser handles payload with Grok Bot")
    func testCursorPayloadWithGrokBot() throws {
        let json = """
        {
            "plan": "Included in Pro",
            "on_demand_spend": 0.0,
            "cursor_models": {
                "used_percentage": 48.0,
                "label": "Cursor Models · Monthly"
            },
            "grok_bot": {
                "used_percentage": 6.0,
                "label": "Grok Bot · Weekly",
                "resets_at": "2026-09-10T10:44:57.000Z"
            }
        }
        """

        let provider = CursorProvider()
        let snapshot = try provider.parseUsagePayload(data: Data(json.utf8))
        #expect(snapshot.metrics.count == 2)
        let grokMetric = try #require(snapshot.metrics.first { $0.id == "grok_bot" })
        #expect(grokMetric.usedPercentage == 6.0)
        #expect(grokMetric.remainingPercentage == 94.0)
        #expect(grokMetric.resetsAt != nil)
    }

    @Test("Cursor decodes base64url user IDs from JWT credentials")
    func testCursorJWTUserIdParser() {
        let payload = "eyJzdWIiOiJ1c2VyMTAwIiwieCI6IsO_In0"
        let token = "header.\(payload).signature"

        #expect(CursorProvider().parseUserIdFromJWT(token) == "user100")
    }

    @Test("Provider logo asset names map to bundled product marks")
    func testProviderLogoAssetNames() {
        #expect(ProviderType.antigravity.logoAssetName == "gemini")
        #expect(ProviderType.codex.logoAssetName == "chatgpt")
        #expect(ProviderType.claude.logoAssetName == "claude")
        #expect(ProviderType.cursor.logoAssetName == "cursor")
    }

    @Test("AppGroupStore saves and loads snapshots")
    func testAppGroupStore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AppGroupStore(customDirectoryURL: tempDir)
        let sample = ProviderUsageSnapshot(
            provider: .antigravity,
            planName: "Google AI Pro",
            metrics: []
        )

        try store.saveSnapshot(sample)
        let loaded = store.loadSnapshot(for: .antigravity)

        #expect(loaded != nil)
        #expect(loaded?.provider == .antigravity)
        #expect(loaded?.planName == "Google AI Pro")
    }

    @Test("MetricRowView formats absolute reset dates across ranges")
    func testMetricRowViewAbsoluteResetDateFormatting() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 27
        components.hour = 12
        components.minute = 0
        let baseDate = calendar.date(from: components)!

        let todayDate = baseDate.addingTimeInterval(3 * 3600 + 45 * 60)
        let todayStr = MetricRowView.formatAbsoluteResetDate(todayDate, relativeTo: baseDate, calendar: calendar)
        #expect(todayStr.hasPrefix("Today, "))

        let tomorrowDate = baseDate.addingTimeInterval(26 * 3600)
        let tomorrowStr = MetricRowView.formatAbsoluteResetDate(tomorrowDate, relativeTo: baseDate, calendar: calendar)
        #expect(tomorrowStr.hasPrefix("Tmr, "))

        let fourDaysDate = baseDate.addingTimeInterval(4 * 86400)
        let weekdayStr = MetricRowView.formatAbsoluteResetDate(fourDaysDate, relativeTo: baseDate, calendar: calendar)
        #expect(weekdayStr.hasPrefix("Mon, "))

        let twelveDaysDate = baseDate.addingTimeInterval(12 * 86400)
        let laterStr = MetricRowView.formatAbsoluteResetDate(twelveDaysDate, relativeTo: baseDate, calendar: calendar)
        #expect(laterStr.contains("Sep 8"))
    }

    @Test("MetricRowView reset status displays duration even when depleted")
    func testMetricRowViewResetStatusDoesNotShowLimitReachedWhenDepleted() {
        let baseDate = Date()
        let futureDate = baseDate.addingTimeInterval(5 * 86400 + 23 * 3600)
        let depletedMetric = LimitMetric(
            id: "claude_gpt_weekly",
            label: "Claude & GPT · Weekly Limit",
            usedPercentage: 100.0,
            remainingPercentage: 0.0,
            resetsAt: futureDate,
            resetInDescription: "5d 23h"
        )

        let status = MetricRowView.formatResetStatus(for: depletedMetric, relativeTo: baseDate)
        #expect(!status.contains("Limit reached"))
        #expect(status.contains("5d 23h remaining"))
    }

    @Test("MetricRowView headline leads with window and reset, model line carries class")
    func testMetricRowViewHeadlineAndModelLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 27
        components.hour = 12
        components.minute = 0
        let baseDate = calendar.date(from: components)!

        let weeklyDate = baseDate.addingTimeInterval(4 * 86400)
        let antigravityMetric = LimitMetric(
            id: "gemini_weekly",
            label: "Gemini Models · Weekly Limit",
            usedPercentage: 41.0,
            remainingPercentage: 59.0,
            resetsAt: weeklyDate
        )
        let antigravityHeadline = MetricRowView.formatHeadline(for: antigravityMetric, relativeTo: baseDate, calendar: calendar)
        #expect(antigravityHeadline.hasPrefix("Weekly · Mon, "))
        #expect(MetricRowView.formatModelLine(for: antigravityMetric) == "Gemini Models")

        let codexDate = baseDate.addingTimeInterval(3 * 3600 + 43 * 60)
        let codexMetric = LimitMetric(
            id: "codex_5hour",
            label: "5-Hour Limit",
            usedPercentage: 15.0,
            remainingPercentage: 85.0,
            resetsAt: codexDate
        )
        let codexHeadline = MetricRowView.formatHeadline(for: codexMetric, relativeTo: baseDate, calendar: calendar)
        #expect(codexHeadline.hasPrefix("5 Hours · Today, "))
        #expect(MetricRowView.formatModelLine(for: codexMetric) == "")
        let twelveDaysDate = baseDate.addingTimeInterval(12 * 86400)
        let cursorMetric = LimitMetric(
            id: "cursor_models",
            label: "Cursor Models · Monthly",
            sublabel: nil,
            usedPercentage: 83.0,
            remainingPercentage: 17.0,
            resetsAt: twelveDaysDate
        )
        let cursorHeadline = MetricRowView.formatHeadline(for: cursorMetric, relativeTo: baseDate, calendar: calendar)
        #expect(cursorHeadline == "Monthly · Sep 8, 14:00")
        #expect(MetricRowView.formatModelLine(for: cursorMetric) == "Cursor Models")
    }

    @Test("Display order groups by model class with weekly before 5-hour")
    func testDisplayOrderGroupsClassThenWindow() {
        let fiveHourGemini = LimitMetric(id: "gemini_5hour", label: "Gemini Models · 5-Hour Limit", usedPercentage: 10, remainingPercentage: 90)
        let weeklyGemini = LimitMetric(id: "gemini_weekly", label: "Gemini Models · Weekly Limit", usedPercentage: 10, remainingPercentage: 90)
        let fiveHourClaudeGPT = LimitMetric(id: "claude_gpt_5hour", label: "Claude & GPT · 5-Hour Limit", usedPercentage: 10, remainingPercentage: 90)
        let weeklyClaudeGPT = LimitMetric(id: "claude_gpt_weekly", label: "Claude & GPT · Weekly Limit", usedPercentage: 10, remainingPercentage: 90)

        let ordered = LimitMetric.displayOrder([fiveHourGemini, weeklyGemini, fiveHourClaudeGPT, weeklyClaudeGPT])
        #expect(ordered.map(\.id) == ["gemini_weekly", "gemini_5hour", "claude_gpt_weekly", "claude_gpt_5hour"])

        let codexFiveHour = LimitMetric(id: "codex_5hour", label: "5-Hour Limit", usedPercentage: 10, remainingPercentage: 90)
        let codexWeekly = LimitMetric(id: "codex_weekly", label: "Weekly Limit", usedPercentage: 10, remainingPercentage: 90)
        let codexOrdered = LimitMetric.displayOrder([codexFiveHour, codexWeekly])
        #expect(codexOrdered.map(\.id) == ["codex_weekly", "codex_5hour"])

        let cursorModels = LimitMetric(id: "cursor_models", label: "Cursor Models", usedPercentage: 10, remainingPercentage: 90)
        let otherModels = LimitMetric(id: "other_models", label: "Other Models", usedPercentage: 10, remainingPercentage: 90)
        let cursorOrdered = LimitMetric.displayOrder([cursorModels, otherModels])
        #expect(cursorOrdered.map(\.id) == ["cursor_models", "other_models"])
    }

    @Test("AppGroupStore saves and loads custom provider order")
    func testAppGroupStoreProviderOrder() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AppGroupStore(customDirectoryURL: tempDir)
        let defaultOrder = store.loadProviderOrder()
        #expect(defaultOrder.contains(.antigravity))
        #expect(defaultOrder.contains(.codex))

        let customOrder: [ProviderType] = [.cursor, .claude, .codex, .antigravity]
        store.saveProviderOrder(customOrder)

        let loadedOrder = store.loadProviderOrder()
        #expect(loadedOrder == customOrder)

}
    private struct StubEmptyClient: AIProviderClient {
        let providerType: ProviderType
        func fetchUsage() async throws -> ProviderUsageSnapshot {
            ProviderUsageSnapshot.empty(for: providerType)
        }
    }

    @Test("Sync engine keeps cached snapshot when fetch returns active but empty")
    func testSyncEngineDoesNotClobberCacheWithEmptySnapshot() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AppGroupStore(customDirectoryURL: tempDir)
        let goodMetric = LimitMetric(id: "gemini_weekly", label: "Gemini Models · Weekly Limit", usedPercentage: 27.0, remainingPercentage: 73.0)
        let goodSnapshot = ProviderUsageSnapshot(provider: .antigravity, planName: "Google AI Pro", metrics: [goodMetric])
        try store.saveSnapshot(goodSnapshot)

        let engine = SyncEngine(store: store)
        await engine.register(client: StubEmptyClient(providerType: .antigravity))

        let refreshed = try await engine.refresh(provider: .antigravity)
        #expect(refreshed.metrics.count == 1)
        #expect(refreshed.metrics.first?.remainingPercentage == 73.0)

        let persisted = store.loadSnapshot(for: .antigravity)
        #expect(persisted?.metrics.count == 1)
    }
}
