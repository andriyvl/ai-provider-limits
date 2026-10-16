import Foundation
import CryptoKit
import SQLite3
import ProviderLimitsCore

enum SmokeFixtureError: Error {
    case sqliteOpenFailed(String)
    case sqliteExecFailed(String)
    case fixtureDeleted(String)
    case fixtureModified(String)
    case secretLeaked(String)
}

final class SyntheticFixtures: @unchecked Sendable {
    let tempHome: URL
    let tempStore: URL
    let screenshotsDir: URL
    let defaultsSuiteName: String

    static let sentinelAntigravity = "SENTINEL_ANTIGRAVITY_TOKEN_77492"
    static let sentinelPiCodex = "SENTINEL_PI_CODEX_TOKEN_11834"
    static let sentinelNativeCodex = "SENTINEL_NATIVE_CODEX_TOKEN_99211"
    static let sentinelClaude = "SENTINEL_CLAUDE_TOKEN_33812"
    static let sentinelCursor = "SENTINEL_CURSOR_TOKEN_44901"
    static let sentinelPiOpenRouter = "SENTINEL_PI_OPENROUTER_KEY_66523"
    static let sentinelOmpSecret = "SENTINEL_OMP_SECRET_88192"

    static let allSentinelSecrets: [String] = [
        sentinelAntigravity,
        sentinelPiCodex,
        sentinelNativeCodex,
        sentinelClaude,
        sentinelCursor,
        sentinelPiOpenRouter,
        sentinelOmpSecret
    ]

    private var initialFileHashes: [String: String] = [:]

    init(baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.temporaryDirectory.appendingPathComponent(
            "smoke-sources-\(UUID().uuidString)",
            isDirectory: true
        )
        self.tempHome = base.appendingPathComponent("home", isDirectory: true)
        self.tempStore = base.appendingPathComponent("store", isDirectory: true)
        self.screenshotsDir = base.appendingPathComponent("screenshots", isDirectory: true)
        self.defaultsSuiteName = "smoke-defaults-\(UUID().uuidString)"
    }

    func createAllFixtures() throws {
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempStore, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

        try createNativeAntigravityDB()
        try createNativeCodexAuth()
        try createNativeClaudeCredentials()
        try createNativeCursorDB()
        try createPiAuthJSON()
        try createOMPDatabase()

        initialFileHashes = try computeFileHashes()
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw SmokeFixtureError.sqliteOpenFailed(url.path)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw SmokeFixtureError.sqliteExecFailed(errorMsg)
        }
    }

    private func createNativeAntigravityDB() throws {
        let dbURL = tempHome.appendingPathComponent(
            "Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
        )
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let oauthTopic = "CoUBChlvYXV0aFRva2VuSW5mb1NlbnRpbmVsS2V5EmgKZENodHplVzUwYUdWMGFXTXRibUYwYVhabExXbGtaUzFoWTJObGMzTVNCa0psWVhKbGNob2NjM2x1ZEdobGRHbGpMVzVoZEdsMlpTMXBaR1V0Y21WbWNtVnphQ0lHQ0lDdW1hUVAQAQ=="
        let userStatusTopic = "CnEKFXVzZXJTdGF0dXNTZW50aW5lbEtleRJYClRHaHBUZVc1MGFHVjBhV01nY0hKbGRtbHZkWE1nWVdOamIzVnVkRG9mYzNSaGJHVXRZV05qYjNWdWRDMWlRR1Y0WVcxd2JHVXVhVzUyWVd4cFpBPT0QAg=="

        let sql = """
        CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        INSERT INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.oauthToken', '\(oauthTopic)');
        INSERT INTO ItemTable (key, value) VALUES ('antigravityUnifiedStateSync.userStatus', '\(userStatusTopic)');
        """
        try executeSQL(sql, at: dbURL)
    }

    private func createNativeCodexAuth() throws {
        let fileURL = tempHome.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let header = "eyJhbGciOiJub25lIn0"
        let payload = "{\"exp\":4102444800,\"sub\":\"user-codex-native\"}"
        let base64Payload = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let jwt = "\(header).\(base64Payload).\(Self.sentinelNativeCodex)"

        let dict: [String: Any] = [
            "tokens": [
                "access_token": jwt,
                "account_id": "codex-workspace-a"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func createNativeClaudeCredentials() throws {
        let fileURL = tempHome.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let dict: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": Self.sentinelClaude,
                "expiresAt": 4102444800000 as Int64,
                "subscriptionType": "Claude Pro"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func createNativeCursorDB() throws {
        let dbURL = tempHome.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sql = """
        CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', '\(Self.sentinelCursor)');
        INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/stripeMembershipAuthId', 'user-stripe-synthetics-1');
        INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/stripeMembershipType', 'pro');
        """
        try executeSQL(sql, at: dbURL)
    }

    private func createPiAuthJSON() throws {
        let fileURL = tempHome.appendingPathComponent(".pi/agent/auth.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let header = "eyJhbGciOiJub25lIn0"
        let payload = "{\"exp\":4102444800,\"sub\":\"user-pi-codex\"}"
        let base64Payload = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let jwt = "\(header).\(base64Payload).\(Self.sentinelPiCodex)"

        let dict: [String: Any] = [
            "openai-codex": [
                "type": "oauth",
                "access": jwt,
                "refresh": "synthetic-pi-refresh",
                "expires": 4102444800000 as Int64,
                "accountId": "pi-codex-workspace-a"
            ],
            "anthropic": [
                "type": "oauth",
                "access": "synthetic-pi-claude",
                "refresh": "synthetic-pi-claude-refresh",
                "expires": 4102444800000 as Int64
            ],
            "openrouter": [
                "type": "api_key",
                "key": "sk-or-v1-\(Self.sentinelPiOpenRouter)"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: fileURL)
    }

    private func createOMPDatabase() throws {
        let dbURL = tempHome.appendingPathComponent(".omp/agent/agent.db")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sql = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT,
            credential_type TEXT,
            data TEXT,
            disabled_cause TEXT,
            identity_key TEXT,
            created_at INTEGER,
            updated_at INTEGER
        );
        CREATE TABLE cache (
            key TEXT PRIMARY KEY,
            value TEXT,
            expires_at INTEGER
        );

        INSERT INTO auth_credentials (id, provider, credential_type, data, disabled_cause)
        VALUES (
            1,
            'google-antigravity',
            'oauth',
            '{"access":"\(Self.sentinelAntigravity)","projectId":"proj-synthetic-antigravity","email":"synthetic@antigravity.invalid"}',
            NULL
        );

        INSERT INTO auth_credentials (id, provider, credential_type, data, disabled_cause)
        VALUES (
            2,
            'openai-codex',
            'oauth',
            '{"access":"eyJhbGciOiJub25lIn0.eyJleHAiOjQxMDI0NDQ4MDB9.\(Self.sentinelOmpSecret)","accountId":"omp-codex-workspace"}',
            NULL
        );

        INSERT INTO auth_credentials (id, provider, credential_type, data, disabled_cause)
        VALUES (
            3,
            'cursor',
            'oauth',
            '{"access":"eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyLW9tcC05OSJ9.synthetic-cursor-omp"}',
            NULL
        );

        INSERT INTO auth_credentials (id, provider, credential_type, data, disabled_cause)
        VALUES (
            4,
            'openrouter',
            'api_key',
            '{"key":"sk-or-v1-omp-key-synthetic"}',
            NULL
        );

        INSERT INTO cache (key, value, expires_at)
        VALUES (
            'session:sticky:google-antigravity:default',
            '{"credentialId":1,"lastUsedAtMs":1791316800000}',
            4102444800
        );
        """
        try executeSQL(sql, at: dbURL)
    }

    func computeFileHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: tempHome, includingPropertiesForKeys: [.isRegularFileKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues?.isRegularFile == true {
                let data = try Data(contentsOf: fileURL)
                let hash = SHA256.hash(data: data)
                let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
                let relativePath = fileURL.path.replacingOccurrences(of: tempHome.path, with: "")
                hashes[relativePath] = hashString
            }
        }
        return hashes
    }

    func verifyFilesUnchanged() throws {
        let currentHashes = try computeFileHashes()
        for (file, initialHash) in initialFileHashes {
            guard let currentHash = currentHashes[file] else {
                throw SmokeFixtureError.fixtureDeleted(file)
            }
            if currentHash != initialHash {
                throw SmokeFixtureError.fixtureModified(file)
            }
        }
    }

    func verifyNoSentinelSecretsLeaked(
        extraStrings: [String] = []
    ) throws {
        var contentsToScan: [String] = extraStrings

        let enumerator = FileManager.default.enumerator(at: tempStore, includingPropertiesForKeys: [.isRegularFileKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues?.isRegularFile == true {
                if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                    contentsToScan.append(text)
                }
            }
        }

        if let defaultsDict = UserDefaults(suiteName: defaultsSuiteName)?.dictionaryRepresentation() {
            for (_, value) in defaultsDict {
                contentsToScan.append(String(describing: value))
            }
        }

        for text in contentsToScan {
            for secret in Self.allSentinelSecrets {
                if text.contains(secret) {
                    throw SmokeFixtureError.secretLeaked(secret)
                }
            }
        }
    }

    func temporarilyHide(path: String) throws -> URL {
        let originalURL = tempHome.appendingPathComponent(path)
        let hiddenURL = tempHome.appendingPathComponent(path + ".hidden")
        try FileManager.default.moveItem(at: originalURL, to: hiddenURL)
        return hiddenURL
    }

    func restoreHidden(path: String) throws {
        let originalURL = tempHome.appendingPathComponent(path)
        let hiddenURL = tempHome.appendingPathComponent(path + ".hidden")
        if FileManager.default.fileExists(atPath: hiddenURL.path) {
            try FileManager.default.moveItem(at: hiddenURL, to: originalURL)
        }
    }
}
