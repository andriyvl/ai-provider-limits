import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

enum OMPCredentialSource {
    static func read(
        provider: ProviderType,
        home: URL,
        now: Date,
        access: @Sendable (URL) -> Bool
    ) -> CredentialSourceRead {
        let url = home.appendingPathComponent(".omp/agent/agent.db")
        guard access(url) else {
            return emptyRead(status: .unreadable)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return emptyRead(status: .missing)
        }

        #if canImport(SQLite3)
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return emptyRead(status: .unreadable)
        }
        defer { sqlite3_close(database) }

        var columnsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(auth_credentials)", -1, &columnsStmt, nil) == SQLITE_OK else {
            return emptyRead(status: .unsupportedFormat)
        }
        defer { sqlite3_finalize(columnsStmt) }

        var columnNames = Set<String>()
        var columnsStep = sqlite3_step(columnsStmt)
        while columnsStep == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(columnsStmt, 1) {
                columnNames.insert(String(cString: namePtr).lowercased())
            }
            columnsStep = sqlite3_step(columnsStmt)
        }

        guard columnsStep == SQLITE_DONE else {
            return emptyRead(status: .unreadable)
        }

        guard columnNames.contains("id"),
              columnNames.contains("provider"),
              columnNames.contains("data") else {
            return emptyRead(status: .unsupportedFormat)
        }

        let hasCredentialType = columnNames.contains("credential_type")
        let hasDisabledCause = columnNames.contains("disabled_cause")

        var stickyMap: [Int64: Double] = [:]
        if provider == .antigravity {
            let cacheQuery = """
            SELECT value, expires_at FROM cache
            WHERE key LIKE 'session:sticky:google-antigravity:%' OR key LIKE 'session:sticky:antigravity:%'
            """
            var cacheStmt: OpaquePointer?
            defer { sqlite3_finalize(cacheStmt) }
            if sqlite3_prepare_v2(database, cacheQuery, -1, &cacheStmt, nil) == SQLITE_OK {
                let nowEpochMs = now.timeIntervalSince1970 * 1000.0
                var cacheStep = sqlite3_step(cacheStmt)
                while cacheStep == SQLITE_ROW {
                    let expiresAt = sqlite3_column_int64(cacheStmt, 1)
                    if Double(expiresAt) > now.timeIntervalSince1970,
                       let valuePtr = sqlite3_column_text(cacheStmt, 0) {
                        let valueStr = String(cString: valuePtr)
                        if let valueData = valueStr.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any],
                           let credIDNumber = CredentialParsing.number(json["credentialId"]),
                           let credentialId = Int64(exactly: credIDNumber),
                           let lastUsedMs = CredentialParsing.number(json["lastUsedAtMs"]),
                           lastUsedMs >= 0, lastUsedMs <= nowEpochMs {
                            if let current = stickyMap[credentialId] {
                                stickyMap[credentialId] = max(current, lastUsedMs)
                            } else {
                                stickyMap[credentialId] = lastUsedMs
                            }
                        }
                    }
                    cacheStep = sqlite3_step(cacheStmt)
                }
            }
        }

        let providerClause: String
        switch provider {
        case .antigravity:
            providerClause = "provider IN ('google-antigravity', 'antigravity')"
        case .codex:
            providerClause = "provider = 'openai-codex'"
        case .cursor:
            providerClause = "provider = 'cursor'"
        case .openRouter:
            providerClause = "provider = 'openrouter'"
        case .claude:
            providerClause = "provider = 'anthropic'"
        }

        let query = """
        SELECT id, provider, data, \
        \(hasCredentialType ? "credential_type" : "NULL"), \
        \(hasDisabledCause ? "disabled_cause" : "NULL") \
        FROM auth_credentials \
        WHERE \(providerClause) \
        ORDER BY id DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &stmt, nil) == SQLITE_OK else {
            return emptyRead(status: .unsupportedFormat)
        }
        defer { sqlite3_finalize(stmt) }

        var candidates: [CredentialCandidate] = []
        var discoveredAccounts: [DiscoveredAccount] = []
        var hasDisabledRecords = false
        var hasExpiredRecords = false
        var hasUnsupportedRecords = false
        let antigravityClient = provider == .antigravity ? loadAntigravityOAuthClient(home: home, access: access) : nil

        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)

            guard let dataPtr = sqlite3_column_text(stmt, 2) else {
                hasUnsupportedRecords = true
                step = sqlite3_step(stmt)
                continue
            }
            let dataStr = String(cString: dataPtr)
            guard let dataBytes = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any] else {
                hasUnsupportedRecords = true
                step = sqlite3_step(stmt)
                continue
            }

            let credentialType: String?
            if sqlite3_column_type(stmt, 3) != SQLITE_NULL, let typePtr = sqlite3_column_text(stmt, 3) {
                credentialType = String(cString: typePtr)
            } else {
                credentialType = nil
            }

            let isRowDisabled = sqlite3_column_type(stmt, 4) != SQLITE_NULL

            if let credentialType {
                let expectedType = provider == .openRouter ? "api_key" : "oauth"
                if credentialType != expectedType {
                    hasUnsupportedRecords = true
                    step = sqlite3_step(stmt)
                    continue
                }
            }

            let parseResult: ParsedCredential?
            switch provider {
            case .antigravity:
                parseResult = parseAntigravity(json: json, now: now, renewalClient: antigravityClient)
            case .codex:
                parseResult = parseCodex(json: json, now: now)
            case .cursor:
                parseResult = parseCursor(json: json, now: now)
            case .openRouter:
                parseResult = parseOpenRouter(json: json)
            case .claude:
                parseResult = parseClaude(json: json, now: now)
            }

            guard let parseResult else {
                hasUnsupportedRecords = true
                step = sqlite3_step(stmt)
                continue
            }

            let isRowExpired = parseResult.isExpired

            let rowStatus: CredentialSourceStatus
            if isRowDisabled {
                rowStatus = .disabled
                hasDisabledRecords = true
            } else if isRowExpired {
                rowStatus = .expired
                hasExpiredRecords = true
            } else {
                rowStatus = .availableLocally
            }

            if let ref = parseResult.reference, let label = parseResult.accountLabel {
                if let index = discoveredAccounts.firstIndex(where: { $0.reference == ref }) {
                    discoveredAccounts[index].status = prioritizedAccountStatus(
                        current: discoveredAccounts[index].status,
                        new: rowStatus
                    )
                } else {
                    discoveredAccounts.append(DiscoveredAccount(reference: ref, label: label, status: rowStatus))
                }
            }

            if rowStatus == .availableLocally {
                let lastUsed = stickyMap[rowID]
                candidates.append(CredentialCandidate(
                    sourceID: "omp.agent-db",
                    reference: parseResult.reference,
                    payload: parseResult.payload,
                    expiresAt: parseResult.expiresAt,
                    rowID: rowID,
                    lastUsedAt: lastUsed
                ))
            }

            step = sqlite3_step(stmt)
        }

        guard step == SQLITE_DONE else {
            return emptyRead(status: .unreadable)
        }

        if provider == .antigravity {
            candidates.sort { lhs, rhs in
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (left?, right?):
                    if left != right { return left > right }
                    return lhs.rowID > rhs.rowID
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.rowID > rhs.rowID
                }
            }
        }

        let finalStatus: CredentialSourceStatus
        if !candidates.isEmpty {
            finalStatus = .availableLocally
        } else if hasDisabledRecords {
            finalStatus = .disabled
        } else if hasExpiredRecords {
            finalStatus = .expired
        } else if hasUnsupportedRecords {
            finalStatus = .unsupportedFormat
        } else {
            finalStatus = .missing
        }

        let accounts = discoveredAccounts.map {
            CredentialAccountDescriptor(reference: $0.reference, label: $0.label, status: $0.status)
        }

        return CredentialSourceRead(
            descriptor: CredentialSourceDescriptor(
                id: "omp.agent-db",
                label: "OMP",
                location: "~/.omp/agent/agent.db",
                status: finalStatus,
                accounts: accounts
            ),
            candidates: candidates
        )
        #else
        return emptyRead(status: .unsupportedFormat)
        #endif
    }

    private static func emptyRead(status: CredentialSourceStatus) -> CredentialSourceRead {
        CredentialSourceRead(
            descriptor: CredentialSourceDescriptor(
                id: "omp.agent-db",
                label: "OMP",
                location: "~/.omp/agent/agent.db",
                status: status,
                accounts: []
            ),
            candidates: []
        )
    }

    private static func prioritizedAccountStatus(
        current: CredentialSourceStatus,
        new: CredentialSourceStatus
    ) -> CredentialSourceStatus {
        if current == .availableLocally || new == .availableLocally {
            return .availableLocally
        }
        if current == .disabled || new == .disabled {
            return .disabled
        }
        if current == .expired || new == .expired {
            return .expired
        }
        return new
    }

    private static func parseAntigravity(
        json: [String: Any],
        now: Date,
        renewalClient: (id: String, secret: String)?
    ) -> ParsedCredential? {
        let token = CredentialParsing.nonempty(json["access"]) ?? CredentialParsing.nonempty(json["accessToken"])
        let projectId = CredentialParsing.nonempty(json["projectId"])
        guard let token, let projectId else { return nil }

        let email = CredentialParsing.nonempty(json["email"])
        let accountId = CredentialParsing.nonempty(json["accountId"])
        let userIdentifier = accountId ?? email

        let reference: CredentialReference?
        let accountLabel: String?
        if let userIdentifier, userIdentifier != token, userIdentifier != projectId {
            guard let tupleData = try? JSONSerialization.data(withJSONObject: [userIdentifier, projectId]),
                  let tupleString = String(data: tupleData, encoding: .utf8) else {
                return nil
            }
            reference = CredentialReference(sourceID: "omp.agent-db", accountID: tupleString)
            accountLabel = "\(userIdentifier) (\(projectId))"
        } else {
            reference = nil
            accountLabel = nil
        }

        let (declaredSeconds, jwtSeconds, isExpired, isMalformed) = evaluateExpiry(json: json, token: token, now: now)
        guard !isMalformed else { return nil }

        let expiresAt: Double?
        switch (declaredSeconds, jwtSeconds) {
        case let (decl?, jwt?):
            expiresAt = min(decl, jwt)
        case let (decl?, nil):
            expiresAt = decl
        case let (nil, jwt?):
            expiresAt = jwt
        case (nil, nil):
            expiresAt = nil
        }

        // Google access tokens last about an hour and omp renews them only when it calls Antigravity.
        // With the stored refresh token and omp's OAuth client, the provider renews in memory instead.
        var credentials = AntigravityCredentials(accessToken: token, projectId: projectId, email: email)
        if isExpired, let refreshToken = CredentialParsing.nonempty(json["refresh"]), let renewalClient {
            credentials.renewal = AntigravityRenewal(
                refreshToken: refreshToken, clientID: renewalClient.id, clientSecret: renewalClient.secret
            )
        }
        return ParsedCredential(
            payload: .antigravity(credentials),
            reference: reference,
            accountLabel: accountLabel,
            expiresAt: expiresAt,
            isExpired: isExpired && credentials.renewal == nil
        )
    }

    /// omp's installed source holds Antigravity's installed-app OAuth client as base64 literals. Reading it
    /// at runtime keeps those values out of this repository; a missing or changed file disables renewal.
    private static func loadAntigravityOAuthClient(home: URL, access: (URL) -> Bool) -> (id: String, secret: String)? {
        let url = home.appendingPathComponent(
            ".bun/install/global/node_modules/@oh-my-pi/pi-ai/src/registry/oauth/google-antigravity.ts"
        )
        guard access(url), let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func decodedLiteral(_ name: String) -> String? {
            let pattern = name + #"\s*=\s*decode\(\s*"[A-Za-z0-9+/=]+""#
            guard let match = source.range(of: pattern, options: .regularExpression),
                  let quote = source[match].firstIndex(of: "\""),
                  let data = Data(base64Encoded: String(source[match][source.index(after: quote)...].prefix { $0 != "\"" })),
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
            return value
        }
        guard let id = decodedLiteral("CLIENT_ID"), let secret = decodedLiteral("CLIENT_SECRET") else { return nil }
        return (id, secret)
    }

    private static func parseCodex(json: [String: Any], now: Date) -> ParsedCredential? {
        let token = CredentialParsing.nonempty(json["access"]) ?? CredentialParsing.nonempty(json["accessToken"])
        guard let token else { return nil }

        var accountId = CredentialParsing.nonempty(json["accountId"])
        if accountId == nil, let accountObj = json["account"] as? [String: Any] {
            accountId = CredentialParsing.nonempty(accountObj["id"])
        }
        if accountId == token {
            accountId = nil
        }

        let reference = accountId.map { CredentialReference(sourceID: "omp.agent-db", accountID: $0) }
        let accountLabel = accountId

        let (declaredSeconds, jwtSeconds, isExpired, isMalformed) = evaluateExpiry(json: json, token: token, now: now)
        guard !isMalformed else { return nil }

        let expiresAt = jwtSeconds ?? declaredSeconds

        let credentials = CodexCredentials(accessToken: token, accountId: accountId)
        return ParsedCredential(
            payload: .codex(credentials),
            reference: reference,
            accountLabel: accountLabel,
            expiresAt: expiresAt,
            isExpired: isExpired
        )
    }

    private static func parseClaude(json: [String: Any], now: Date) -> ParsedCredential? {
        guard let token = CredentialParsing.nonempty(json["access"]) ?? CredentialParsing.nonempty(json["accessToken"]) else {
            return nil
        }
        let accountId = CredentialParsing.nonempty(json["accountId"]).flatMap { $0 == token ? nil : $0 }
        let (declaredSeconds, jwtSeconds, isExpired, isMalformed) = evaluateExpiry(json: json, token: token, now: now)
        guard !isMalformed else { return nil }

        // Anthropic access tokens last about 8 hours and omp renews them only when it calls Claude.
        // With the stored refresh token, the provider renews in memory instead.
        var credentials = ClaudeCredentials(accessToken: token)
        if isExpired, let refreshToken = CredentialParsing.nonempty(json["refresh"]) {
            credentials.renewal = ClaudeRenewal(refreshToken: refreshToken)
        }
        return ParsedCredential(
            payload: .claude(credentials),
            reference: accountId.map { CredentialReference(sourceID: "omp.agent-db", accountID: $0) },
            accountLabel: accountId.map { CredentialParsing.nonempty(json["email"]) ?? $0 },
            expiresAt: jwtSeconds ?? declaredSeconds,
            isExpired: isExpired && credentials.renewal == nil
        )
    }

    private static func parseCursor(json: [String: Any], now: Date) -> ParsedCredential? {
        let token = CredentialParsing.nonempty(json["access"]) ?? CredentialParsing.nonempty(json["accessToken"])
        guard let token else { return nil }

        guard let claims = CredentialParsing.jwtClaims(token),
              let sub = CredentialParsing.nonempty(claims["sub"]) else {
            return nil
        }

        let (declaredSeconds, jwtSeconds, isExpired, isMalformed) = evaluateExpiry(json: json, token: token, now: now)
        guard !isMalformed else { return nil }

        let expiresAt = jwtSeconds ?? declaredSeconds
        let membershipType = CredentialParsing.nonempty(json["membershipType"])
        let credentials = CursorCredentials(accessToken: token, userId: sub, membershipType: membershipType)
        return ParsedCredential(
            payload: .cursor(credentials),
            reference: nil,
            accountLabel: nil,
            expiresAt: expiresAt,
            isExpired: isExpired
        )
    }

    private static func parseOpenRouter(json: [String: Any]) -> ParsedCredential? {
        guard let key = CredentialParsing.nonempty(json["key"]) else { return nil }
        return ParsedCredential(
            payload: .openRouter(key),
            reference: nil,
            accountLabel: nil,
            expiresAt: nil,
            isExpired: false
        )
    }

    private static func evaluateExpiry(
        json: [String: Any],
        token: String?,
        now: Date
    ) -> (declaredSeconds: Double?, jwtSeconds: Double?, isExpired: Bool, isMalformed: Bool) {
        let rawExpires = json["expires"] ?? json["expiresAt"]
        var declaredSeconds: Double?
        if rawExpires != nil {
            guard let ms = CredentialParsing.number(rawExpires) else {
                return (nil, nil, false, true)
            }
            declaredSeconds = ms / 1000.0
        }

        var jwtSeconds: Double?
        if let token, let claims = CredentialParsing.jwtClaims(token) {
            if let rawExp = claims["exp"] {
                guard let s = CredentialParsing.number(rawExp) else {
                    return (nil, nil, false, true)
                }
                jwtSeconds = s
            }
        }

        let isExpired = (declaredSeconds.map { $0 <= now.timeIntervalSince1970 } ?? false)
            || (jwtSeconds.map { $0 <= now.timeIntervalSince1970 } ?? false)
        return (declaredSeconds, jwtSeconds, isExpired, false)
    }
}

private struct ParsedCredential {
    let payload: CredentialPayload
    let reference: CredentialReference?
    let accountLabel: String?
    let expiresAt: Double?
    let isExpired: Bool
}

private struct DiscoveredAccount {
    let reference: CredentialReference
    let label: String
    var status: CredentialSourceStatus
}
