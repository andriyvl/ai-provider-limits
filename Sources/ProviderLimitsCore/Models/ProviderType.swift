import Foundation

public enum ProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case antigravity
    case codex
    case claude
    case cursor
    case openRouter = "openrouter"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .antigravity: return "Google Antigravity"
        case .codex: return "OpenAI Codex"
        case .claude: return "Anthropic Claude"
        case .cursor: return "Cursor"
        case .openRouter: return "OpenRouter"
        }
    }

    public var shortName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .openRouter: return "OpenRouter"
        }
    }

    public var logoAssetName: String {
        switch self {
        case .antigravity: return "gemini"
        case .codex: return "chatgpt"
        case .claude: return "claude"
        case .cursor: return "cursor"
        case .openRouter: return "openrouter"
        }
    }

    public var systemIconName: String {
        switch self {
        case .antigravity: return "sparkles"
        case .codex: return "terminal"
        case .claude: return "brain"
        case .cursor: return "chevron.left.forwardslash.chevron.right"
        case .openRouter: return "arrow.triangle.branch"
        }
    }

    var usageDetailsURL: URL? {
        switch self {
        case .antigravity: return nil
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .claude: return URL(string: "https://claude.ai/settings/usage")
        case .cursor: return URL(string: "https://cursor.com/dashboard/spending")
        case .openRouter: return URL(string: "https://openrouter.ai/activity")
        }
    }

    var usageDetailsTooltip: String {
        switch self {
        case .antigravity:
            return "Usage limits are only accessible in the Antigravity desktop app."
        case .codex, .claude, .cursor, .openRouter:
            return "Open \(displayName) usage details in your browser."
        }
    }
}
