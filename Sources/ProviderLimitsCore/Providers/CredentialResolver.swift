import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public enum CredentialSelection: Codable, Equatable, Sendable {
    case automatic
    case source(String, accountID: String? = nil)
}

public struct CredentialReference: Codable, Hashable, Sendable {
    public let sourceID: String
    public let accountID: String

    public init(sourceID: String, accountID: String) {
        self.sourceID = sourceID
        self.accountID = accountID
    }
}

public enum CredentialSourceStatus: String, Codable, Sendable {
    case availableLocally
    case missing
    case unreadable
    case unsupportedFormat
    case expired
    case disabled
}

public struct CredentialAccountDescriptor: Codable, Equatable, Sendable {
    public let reference: CredentialReference
    public let label: String
    public let status: CredentialSourceStatus
}

public struct CredentialSourceDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let location: String
    public let status: CredentialSourceStatus
    public let accounts: [CredentialAccountDescriptor]
}

public struct CredentialDiscovery: Codable, Equatable, Sendable {
    public let provider: ProviderType
    public let sources: [CredentialSourceDescriptor]
}

enum CredentialPayload: Sendable {
    case antigravity(AntigravityCredentials)
    case nativeAntigravity(NativeAntigravityCredentials)
    case codex(CodexCredentials)
    case claude(ClaudeCredentials)
    case cursor(CursorCredentials)
    case openRouter(String)
}

struct CredentialCandidate: Sendable {
    let sourceID: String
    let reference: CredentialReference?
    let payload: CredentialPayload
    let expiresAt: TimeInterval?
    var rowID: Int64 = 0
    var lastUsedAt: Double? = nil
}

struct CredentialSourceRead: Sendable {
    let descriptor: CredentialSourceDescriptor
    let candidates: [CredentialCandidate]
}

struct CredentialResolution: Sendable {
    let discovery: CredentialDiscovery
    let candidates: [CredentialCandidate]
}

public struct CredentialResolver: Sendable {
    private let home: URL
    private let environment: [String: String]
    private let clock: @Sendable () -> Date
    private let access: @Sendable (URL) -> Bool
    private let readFile: @Sendable (URL) throws -> Data

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping @Sendable () -> Date = { Date() },
        access: @escaping @Sendable (URL) -> Bool = { _ in true },
        readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.home = home
        self.environment = environment
        self.clock = clock
        self.access = access
        self.readFile = readFile
    }

    public func discover(provider: ProviderType) async -> CredentialDiscovery {
        await resolve(provider: provider).discovery
    }

    func resolve(
        provider: ProviderType,
        selection: CredentialSelection = .automatic
    ) async -> CredentialResolution {
        await Task.detached {
            let sources = readSources(provider: provider, now: clock())
            var candidates = sources.flatMap(\.candidates)
            if case let .source(sourceID, accountID) = selection {
                candidates.removeAll {
                    $0.sourceID != sourceID || (accountID != nil && $0.reference?.accountID != accountID)
                }
            }
            if provider == .codex {
                let order = sources.map { $0.descriptor.id }
                candidates.sort {
                    if $0.expiresAt != $1.expiresAt {
                        return ($0.expiresAt ?? 0) > ($1.expiresAt ?? 0)
                    }
                    let leftSource = order.firstIndex(of: $0.sourceID) ?? order.count
                    let rightSource = order.firstIndex(of: $1.sourceID) ?? order.count
                    if leftSource != rightSource { return leftSource < rightSource }
                    let leftAccount = $0.reference?.accountID ?? ""
                    let rightAccount = $1.reference?.accountID ?? ""
                    if leftAccount != rightAccount { return leftAccount < rightAccount }
                    return $0.rowID > $1.rowID
                }
            }
            return CredentialResolution(
                discovery: CredentialDiscovery(provider: provider, sources: sources.map(\.descriptor)),
                candidates: candidates
            )
        }.value
    }

    private func readSources(provider: ProviderType, now: Date) -> [CredentialSourceRead] {
        switch provider {
        case .antigravity:
            return [
                NativeAntigravityCredentialSource.read(home: home, now: now, access: access),
                OMPCredentialSource.read(provider: provider, home: home, now: now, access: access)
            ]
        case .codex:
            return [
                readNativeJSON(provider: provider, now: now),
                PiCredentialSource.read(provider: provider, home: home, environment: environment, now: now, access: access, readFile: readFile),
                OMPCredentialSource.read(provider: provider, home: home, now: now, access: access)
            ]
        case .claude:
            return [
                readNativeJSON(provider: provider, now: now),
                PiCredentialSource.read(provider: provider, home: home, environment: environment, now: now, access: access, readFile: readFile),
                OMPCredentialSource.read(provider: provider, home: home, now: now, access: access)
            ]
        case .cursor:
            return [
                readCursor(now: now),
                OMPCredentialSource.read(provider: provider, home: home, now: now, access: access)
            ]
        case .openRouter:
            let key = CredentialParsing.nonempty(environment["OPENROUTER_API_KEY"])
            let sourceID = "process.openrouter-key"
            let descriptor = CredentialSourceDescriptor(
                id: sourceID, label: "Launch environment", location: "OPENROUTER_API_KEY",
                status: key == nil ? .missing : .availableLocally, accounts: []
            )
            let candidates = key.map {
                [CredentialCandidate(sourceID: sourceID, reference: nil, payload: .openRouter($0), expiresAt: nil)]
            } ?? []
            return [
                CredentialSourceRead(descriptor: descriptor, candidates: candidates),
                PiCredentialSource.read(provider: provider, home: home, environment: environment, now: now, access: access, readFile: readFile),
                OMPCredentialSource.read(provider: provider, home: home, now: now, access: access)
            ]
        }
    }

    private func readNativeJSON(provider: ProviderType, now: Date) -> CredentialSourceRead {
        let isCodex = provider == .codex
        let sourceID = isCodex ? "native.codex-auth" : "native.claude-credentials"
        let relativePath = isCodex ? ".codex/auth.json" : ".claude/.credentials.json"
        let label = isCodex ? "Codex" : "Claude"
        let url = home.appendingPathComponent(relativePath)
        func result(_ status: CredentialSourceStatus) -> CredentialSourceRead {
            CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID, label: label, location: "~/" + relativePath, status: status, accounts: []
                ), candidates: []
            )
        }
        guard access(url) else { return result(.unreadable) }
        let data: Data
        do {
            data = try readFile(url)
        } catch {
            let error = error as NSError
            return result(error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
                ? .missing : .unreadable)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return result(.unsupportedFormat)
        }
        let payload: CredentialPayload
        let accountID: String?
        let expiresAt: Double?
        if isCodex {
            guard let credentials = CredentialParsing.parseCodexCredentials(json: json),
                  let token = CredentialParsing.nonempty(credentials.accessToken) else {
                return result(.unsupportedFormat)
            }
            accountID = CredentialParsing.nonempty(credentials.accountId).flatMap { $0 == token ? nil : $0 }
            payload = .codex(CodexCredentials(accessToken: token, accountId: accountID))
            let expiry = CredentialParsing.jwtClaims(token)?["exp"]
            if expiry != nil && CredentialParsing.number(expiry) == nil { return result(.unsupportedFormat) }
            expiresAt = CredentialParsing.number(expiry)
        } else {
            guard let credentials = CredentialParsing.parseClaudeCredentials(json: json),
                  let token = CredentialParsing.nonempty(credentials.accessToken) else {
                return result(.unsupportedFormat)
            }
            payload = .claude(ClaudeCredentials(accessToken: token, subscriptionType: credentials.subscriptionType))
            accountID = nil
            let oauth = json["claudeAiOauth"] as? [String: Any]
            let expiry = oauth?["expiresAt"] ?? json["expiresAt"]
            if expiry != nil && CredentialParsing.number(expiry) == nil { return result(.unsupportedFormat) }
            expiresAt = CredentialParsing.number(expiry).map { $0 / 1000 }
        }
        return singleCredential(
            sourceID: sourceID, label: label, location: "~/" + relativePath,
            payload: payload, accountID: accountID, expiresAt: expiresAt, now: now
        )
    }

    private func readCursor(now: Date) -> CredentialSourceRead {
        let sourceID = "native.cursor-state"
        let relativePath = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        let url = home.appendingPathComponent(relativePath)
        func result(_ status: CredentialSourceStatus) -> CredentialSourceRead {
            CredentialSourceRead(
                descriptor: CredentialSourceDescriptor(
                    id: sourceID, label: "Cursor", location: "~/" + relativePath, status: status, accounts: []
                ), candidates: []
            )
        }
        guard access(url) else { return result(.unreadable) }
        guard FileManager.default.fileExists(atPath: url.path) else { return result(.missing) }
        #if canImport(SQLite3)
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard openStatus == SQLITE_OK else { return result(.unreadable) }
        var statement: OpaquePointer?
        let query = """
        SELECT key, value FROM ItemTable
        WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/stripeMembershipAuthId', 'cursorAuth/stripeMembershipType')
        """
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return result(.unsupportedFormat)
        }
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                values[String(cString: key)] = String(cString: value)
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { return result(.unreadable) }
        guard !values.isEmpty else { return result(.missing) }
        guard let token = CredentialParsing.nonempty(values["cursorAuth/accessToken"]),
              let userID = CredentialParsing.nonempty(values["cursorAuth/stripeMembershipAuthId"]),
              userID != token else { return result(.unsupportedFormat) }
        let expiry = CredentialParsing.jwtClaims(token)?["exp"]
        if expiry != nil && CredentialParsing.number(expiry) == nil { return result(.unsupportedFormat) }
        return singleCredential(
            sourceID: sourceID, label: "Cursor", location: "~/" + relativePath,
            payload: .cursor(CursorCredentials(
                accessToken: token, userId: userID,
                membershipType: CredentialParsing.nonempty(values["cursorAuth/stripeMembershipType"])
            )), accountID: userID, expiresAt: CredentialParsing.number(expiry), now: now
        )
        #else
        return result(.unsupportedFormat)
        #endif
    }

    private func singleCredential(
        sourceID: String, label: String, location: String, payload: CredentialPayload,
        accountID: String?, expiresAt: Double?, now: Date
    ) -> CredentialSourceRead {
        let status: CredentialSourceStatus = expiresAt.map { $0 <= now.timeIntervalSince1970 } == true
            ? .expired : .availableLocally
        let reference = accountID.map { CredentialReference(sourceID: sourceID, accountID: $0) }
        let accounts = reference.map {
            [CredentialAccountDescriptor(reference: $0, label: $0.accountID, status: status)]
        } ?? []
        let candidates = status == .availableLocally ? [CredentialCandidate(
            sourceID: sourceID, reference: reference, payload: payload, expiresAt: expiresAt
        )] : []
        return CredentialSourceRead(
            descriptor: CredentialSourceDescriptor(
                id: sourceID, label: label, location: location, status: status, accounts: accounts
            ), candidates: candidates
        )
    }
}
enum CredentialParsing {
    static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func parseCodexCredentials(data: Data) -> CodexCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseCodexCredentials(json: json)
    }

    static func parseCodexCredentials(json: [String: Any]) -> CodexCredentials? {
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

    static func parseClaudeCredentials(data: Data) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseClaudeCredentials(json: json)
    }

    static func parseClaudeCredentials(json: [String: Any]) -> ClaudeCredentials? {
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
}
