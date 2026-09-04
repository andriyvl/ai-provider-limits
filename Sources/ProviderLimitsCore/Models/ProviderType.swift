import Foundation

public enum ProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case antigravity
    case codex
    case claude
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .antigravity: return "Google Antigravity"
        case .codex: return "OpenAI Codex"
        case .claude: return "Anthropic Claude"
        case .cursor: return "Cursor"
        }
    }

    public var shortName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        }
    }

    public var logoAssetName: String {
        switch self {
        case .antigravity: return "gemini"
        case .codex: return "chatgpt"
        case .claude: return "claude"
        case .cursor: return "cursor"
        }
    }

    public var systemIconName: String {
        switch self {
        case .antigravity: return "sparkles"
        case .codex: return "terminal"
        case .claude: return "brain"
        case .cursor: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
