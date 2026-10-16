import Foundation

enum PiCredentialSource {
    static let sourceID = "pi.auth-json"
    static let label = "Pi"

    static func resolveLocation(
        home: URL,
        environment: [String: String]
    ) -> (fileURL: URL, displayLocation: String) {
        guard let dirOverride = CredentialParsing.nonempty(environment["PI_CODING_AGENT_DIR"]) else {
            return (home.appendingPathComponent(".pi/agent/auth.json"), "~/.pi/agent/auth.json")
        }

        let fileURL: URL
        let displayDir: String

        if dirOverride == "~" {
            fileURL = home.appendingPathComponent("auth.json")
            displayDir = "~"
        } else if dirOverride.hasPrefix("~/") {
            let relative = String(dirOverride.dropFirst(2))
            fileURL = home.appendingPathComponent(relative).appendingPathComponent("auth.json")
            displayDir = dirOverride.hasSuffix("/") ? String(dirOverride.dropLast()) : dirOverride
        } else if dirOverride.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: dirOverride).appendingPathComponent("auth.json")
            if dirOverride == home.path {
                displayDir = "~"
            } else if dirOverride.hasPrefix(home.path + "/") {
                displayDir = "~/" + dirOverride.dropFirst(home.path.count + 1)
            } else if dirOverride.hasPrefix("/Users/") {
                displayDir = dirOverride.replacingOccurrences(
                    of: #"^/Users/[^/]+"#,
                    with: "~",
                    options: .regularExpression
                )
            } else {
                displayDir = dirOverride
            }
        } else {
            fileURL = home.appendingPathComponent(dirOverride).appendingPathComponent("auth.json")
            displayDir = "~/" + dirOverride
        }

        let cleanDisplay = displayDir.hasSuffix("/") ? String(displayDir.dropLast()) : displayDir
        return (fileURL, cleanDisplay + "/auth.json")
    }

    static func read(
        provider: ProviderType,
        home: URL,
        environment: [String: String],
        now: Date,
        access: @Sendable (URL) -> Bool,
        readFile: @Sendable (URL) throws -> Data
    ) -> CredentialSourceRead {
        let (fileURL, location) = resolveLocation(home: home, environment: environment)

        func emptyRead(status: CredentialSourceStatus) -> CredentialSourceRead {
            CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID,
                    label: label,
                    location: location,
                    status: status,
                    accounts: []
                ),
                candidates: []
            )
        }

        guard provider == .codex || provider == .claude || provider == .openRouter else {
            return emptyRead(status: .missing)
        }

        guard access(fileURL) else {
            return emptyRead(status: .unreadable)
        }

        let data: Data
        do {
            data = try readFile(fileURL)
        } catch {
            let nsError = error as NSError
            let isMissing = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
            return emptyRead(status: isMissing ? .missing : .unreadable)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return emptyRead(status: .unsupportedFormat)
        }

        switch provider {
        case .codex:
            return readCodex(json: json, location: location, now: now)
        case .claude:
            return readClaude(json: json, location: location, now: now)
        case .openRouter:
            return readOpenRouter(json: json, location: location)
        default:
            return emptyRead(status: .missing)
        }
    }

    private static func readCodex(
        json: [String: Any],
        location: String,
        now: Date
    ) -> CredentialSourceRead {
        func emptyRead(status: CredentialSourceStatus) -> CredentialSourceRead {
            CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID,
                    label: label,
                    location: location,
                    status: status,
                    accounts: []
                ),
                candidates: []
            )
        }

        guard let raw = json["openai-codex"] else {
            return emptyRead(status: .missing)
        }
        guard let record = raw as? [String: Any],
              record["type"] as? String == "oauth",
              let access = CredentialParsing.nonempty(record["access"]),
              record["refresh"] is String,
              let expiresMs = CredentialParsing.number(record["expires"]),
              let accountId = CredentialParsing.nonempty(record["accountId"]),
              accountId != access, accountId != record["refresh"] as? String else {
            return emptyRead(status: .unsupportedFormat)
        }

        let fileExpirySeconds = expiresMs / 1000.0
        let claims = CredentialParsing.jwtClaims(access)
        let jwtExp = claims?["exp"]
        if jwtExp != nil && CredentialParsing.number(jwtExp) == nil {
            return emptyRead(status: .unsupportedFormat)
        }
        let jwtExpirySeconds = CredentialParsing.number(jwtExp)

        let isFileExpired = fileExpirySeconds <= now.timeIntervalSince1970
        let isJwtExpired = jwtExpirySeconds.map { $0 <= now.timeIntervalSince1970 } ?? false
        let isExpired = isFileExpired || isJwtExpired
        let status: CredentialSourceStatus = isExpired ? .expired : .availableLocally

        let reference = CredentialReference(sourceID: sourceID, accountID: accountId)
        let accounts = [CredentialAccountDescriptor(reference: reference, label: accountId, status: status)]
        let candidate = isExpired ? nil : CredentialCandidate(
            sourceID: sourceID,
            reference: reference,
            payload: .codex(CodexCredentials(accessToken: access, accountId: accountId)),
            expiresAt: jwtExpirySeconds
        )

        return CredentialSourceRead(
            descriptor: CredentialSourceDescriptor(
                id: sourceID,
                label: label,
                location: location,
                status: status,
                accounts: accounts
            ),
            candidates: candidate.map { [$0] } ?? []
        )
    }

    private static func readClaude(
        json: [String: Any],
        location: String,
        now: Date
    ) -> CredentialSourceRead {
        func emptyRead(status: CredentialSourceStatus) -> CredentialSourceRead {
            CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID,
                    label: label,
                    location: location,
                    status: status,
                    accounts: []
                ),
                candidates: []
            )
        }

        guard let raw = json["anthropic"] else {
            return emptyRead(status: .missing)
        }
        guard let record = raw as? [String: Any],
              record["type"] as? String == "oauth",
              let access = CredentialParsing.nonempty(record["access"]),
              record["refresh"] is String,
              let expiresMs = CredentialParsing.number(record["expires"]) else {
            return emptyRead(status: .unsupportedFormat)
        }

        let fileExpirySeconds = expiresMs / 1000.0
        let isExpired = fileExpirySeconds <= now.timeIntervalSince1970
        let status: CredentialSourceStatus = isExpired ? .expired : .availableLocally

        let candidate = isExpired ? nil : CredentialCandidate(
            sourceID: sourceID,
            reference: nil,
            payload: .claude(ClaudeCredentials(accessToken: access, subscriptionType: nil)),
            expiresAt: fileExpirySeconds
        )

        return CredentialSourceRead(
            descriptor: CredentialSourceDescriptor(
                id: sourceID,
                label: label,
                location: location,
                status: status,
                accounts: []
            ),
            candidates: candidate.map { [$0] } ?? []
        )
    }

    private static func readOpenRouter(
        json: [String: Any],
        location: String
    ) -> CredentialSourceRead {
        func emptyRead(status: CredentialSourceStatus) -> CredentialSourceRead {
            CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID,
                    label: label,
                    location: location,
                    status: status,
                    accounts: []
                ),
                candidates: []
            )
        }

        guard let raw = json["openrouter"] else {
            return emptyRead(status: .missing)
        }
        guard let record = raw as? [String: Any] else {
            return emptyRead(status: .unsupportedFormat)
        }

        let type = record["type"] as? String
        if type == "api_key" {
            guard let key = CredentialParsing.nonempty(record["key"]),
                  !isRejectedKeyExpression(key) else {
                return emptyRead(status: .unsupportedFormat)
            }
            let candidate = CredentialCandidate(
                sourceID: sourceID,
                reference: nil,
                payload: .openRouter(key),
                expiresAt: nil
            )
            return CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID,
                    label: label,
                    location: location,
                    status: .availableLocally,
                    accounts: []
                ),
                candidates: [candidate]
            )
        }

        if type == "oauth" {
            guard let access = CredentialParsing.nonempty(record["access"]),
                  record["refresh"] is String,
                  let expires = CredentialParsing.number(record["expires"]) else {
                return emptyRead(status: .unsupportedFormat)
            }
            let isSentinel = expires == 9007199254740991
            let candidate = CredentialCandidate(
                sourceID: sourceID,
                reference: nil,
                payload: .openRouter(access),
                expiresAt: isSentinel ? nil : (expires / 1000.0)
            )
            return CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID,
                    label: label,
                    location: location,
                    status: .availableLocally,
                    accounts: []
                ),
                candidates: [candidate]
            )
        }

        return emptyRead(status: .unsupportedFormat)
    }

    private static func isRejectedKeyExpression(_ key: String) -> Bool {
        if key.hasPrefix("!") || key.contains("$") {
            return true
        }
        return key.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil
    }
}
