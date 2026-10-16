import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

struct NativeAntigravityCredentials: Sendable {
    let accessToken: String
    let expiresAt: TimeInterval
    let isGCPTOS: Bool
}

enum NativeAntigravityCredentialSource {
    static let sourceID = "native.antigravity-ide"
    static let label = "Antigravity IDE"
    static let relativePath = "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"
    static let location = "~/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"

    static func read(
        home: URL,
        now: Date,
        access: @Sendable (URL) -> Bool
    ) -> CredentialSourceRead {
        let url = home.appendingPathComponent(relativePath)
        guard access(url) else {
            return emptyRead(status: .unreadable)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return emptyRead(status: .missing)
        }
        #if canImport(SQLite3)
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard openStatus == SQLITE_OK else {
            return emptyRead(status: .unreadable)
        }
        var statement: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = 'antigravityUnifiedStateSync.oauthToken'"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return emptyRead(status: .unsupportedFormat)
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            return emptyRead(status: step == SQLITE_DONE ? .missing : .unreadable)
        }
        guard let topicData = extractTopicData(statement: statement) else {
            return emptyRead(status: .unsupportedFormat)
        }
        guard let parsed = parseTopic(data: topicData) else {
            return emptyRead(status: .unsupportedFormat)
        }
        guard let token = CredentialParsing.nonempty(parsed.accessToken),
              parsed.expirySeconds.isFinite,
              parsed.expirySeconds >= 0 else {
            return emptyRead(status: .unsupportedFormat)
        }
        let isExpired = parsed.expirySeconds <= now.timeIntervalSince1970
        let status: CredentialSourceStatus = isExpired ? .expired : .availableLocally
        let candidate = isExpired ? nil : CredentialCandidate(
            sourceID: sourceID,
            reference: nil,
            payload: .nativeAntigravity(NativeAntigravityCredentials(
                accessToken: token,
                expiresAt: parsed.expirySeconds,
                isGCPTOS: parsed.isGCPTOS
            )),
            expiresAt: parsed.expirySeconds
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
        #else
        return emptyRead(status: .unsupportedFormat)
        #endif
    }

    private static func emptyRead(status: CredentialSourceStatus) -> CredentialSourceRead {
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

    #if canImport(SQLite3)
    private static func extractTopicData(statement: OpaquePointer?) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = sqlite3_column_bytes(statement, 0)
        guard count > 0 else { return nil }
        let encoded = Data(bytes: bytes, count: Int(count))
        guard let text = String(data: encoded, encoding: .utf8) else { return nil }
        return Data(base64Encoded: text)
    }
    #endif

    private struct ParsedOAuth {
        let accessToken: String
        let expirySeconds: TimeInterval
        let isGCPTOS: Bool
    }

    private static func parseTopic(data: Data) -> ParsedOAuth? {
        var reader = ProtobufDecoder(data: data)
        var parsed: ParsedOAuth?
        while let field = reader.readField() {
            if field.number == 1, field.wireType == 2,
               let entry = parseTopicDataEntry(data: field.data) {
                parsed = entry
            }
        }
        return reader.isComplete ? parsed : nil
    }

    private static func parseTopicDataEntry(data: Data) -> ParsedOAuth? {
        var reader = ProtobufDecoder(data: data)
        var key: String?
        var rowData: Data?
        while let field = reader.readField() {
            if field.number == 1, field.wireType == 2 {
                key = String(data: field.data, encoding: .utf8)
            } else if field.number == 2, field.wireType == 2 {
                rowData = field.data
            }
        }
        guard reader.isComplete, key == "oauthTokenInfoSentinelKey", let rowData else { return nil }
        return parseRow(data: rowData)
    }

    private static func parseRow(data: Data) -> ParsedOAuth? {
        var reader = ProtobufDecoder(data: data)
        var rowValueBase64: String?
        while let field = reader.readField() {
            if field.number == 1, field.wireType == 2 {
                rowValueBase64 = String(data: field.data, encoding: .utf8)
            }
        }
        guard reader.isComplete, let rowValueBase64,
              let oauthData = Data(base64Encoded: rowValueBase64) else { return nil }
        return parseOAuthTokenInfo(data: oauthData)
    }

    private static func parseOAuthTokenInfo(data: Data) -> ParsedOAuth? {
        var reader = ProtobufDecoder(data: data)
        var accessToken: String?
        var expirySeconds: TimeInterval?
        var isGCPTOS = false
        while let field = reader.readField() {
            switch field.number {
            case 1 where field.wireType == 2:
                accessToken = String(data: field.data, encoding: .utf8)
            case 4 where field.wireType == 2:
                expirySeconds = parseTimestamp(data: field.data)
            case 6 where field.wireType == 0:
                isGCPTOS = field.varintValue != 0
            default:
                break
            }
        }
        guard reader.isComplete, let accessToken, let expirySeconds else { return nil }
        return ParsedOAuth(accessToken: accessToken, expirySeconds: expirySeconds, isGCPTOS: isGCPTOS)
    }

    private static func parseTimestamp(data: Data) -> TimeInterval? {
        var reader = ProtobufDecoder(data: data)
        var seconds: UInt64?
        var nanos: UInt64 = 0
        while let field = reader.readField() {
            if field.number == 1, field.wireType == 0 {
                seconds = field.varintValue
            } else if field.number == 2, field.wireType == 0 {
                nanos = field.varintValue
            }
        }
        guard reader.isComplete, let seconds, seconds <= UInt64(Int64.max), nanos < 1_000_000_000 else { return nil }
        return Double(seconds) + Double(nanos) / 1_000_000_000
    }
}

private struct ProtobufDecoder {
    struct Field {
        let number: Int
        let wireType: Int
        let data: Data
        let varintValue: UInt64
    }

    private let data: Data
    private var offset: Int
    private var isMalformed = false

    var isComplete: Bool { offset == data.endIndex && !isMalformed }

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readField() -> Field? {
        guard !isMalformed, offset < data.endIndex else { return nil }
        isMalformed = true
        guard let tag = readVarint(),
              let fieldNumber = Int(exactly: tag >> 3),
              fieldNumber > 0, fieldNumber <= 536_870_911 else { return nil }
        let wireType = Int(tag & 0x07)
        let field: Field
        switch wireType {
        case 0:
            guard let value = readVarint() else { return nil }
            field = Field(number: fieldNumber, wireType: wireType, data: Data(), varintValue: value)
        case 1, 5:
            let count = wireType == 1 ? 8 : 4
            guard count <= data.endIndex - offset else { return nil }
            let end = offset + count
            field = Field(number: fieldNumber, wireType: wireType, data: data[offset..<end], varintValue: 0)
            offset = end
        case 2:
            guard let length = readVarint(), let count = Int(exactly: length),
                  count <= data.endIndex - offset else { return nil }
            let end = offset + count
            field = Field(number: fieldNumber, wireType: wireType, data: data[offset..<end], varintValue: 0)
            offset = end
        default:
            return nil
        }
        isMalformed = false
        return field
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard offset < data.endIndex else { return nil }
            let byte = data[offset]
            offset += 1
            guard index < 9 || byte <= 1 else { return nil }
            result |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 { return result }
        }
        return nil
    }
}
