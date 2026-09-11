import Foundation

/// A coding agent whose activity Notch can display.
public enum Agent: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// What an agent session is doing right now.
public enum Stage: String, Codable, Sendable {
    case analyzing
    case thinking
    case creating
    case waiting
    case completed
    case failed
}

/// A single normalized activity event emitted by an agent hook.
public struct AgentEvent: Codable, Sendable, Equatable {
    public var agent: Agent
    public var sessionID: String
    public var stage: Stage
    /// Tool name, e.g. "Edit", "Bash", "apply_patch".
    public var tool: String?
    /// Permission message or last assistant line (<= 80 chars).
    public var detail: String?
    /// `TERM_PROGRAM` value or "cursor".
    public var sourceApp: String?
    public var timestamp: Date

    public init(
        agent: Agent,
        sessionID: String,
        stage: Stage,
        tool: String? = nil,
        detail: String? = nil,
        sourceApp: String? = nil,
        timestamp: Date
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.stage = stage
        self.tool = tool
        self.detail = detail
        self.sourceApp = sourceApp
        self.timestamp = timestamp
    }
}
