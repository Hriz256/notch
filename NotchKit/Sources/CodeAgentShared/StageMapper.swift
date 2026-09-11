import Foundation

/// Pure mapping from a parsed agent hook payload to a normalized ``AgentEvent``.
///
/// The mapper never performs I/O, never logs and never mutates global state: it
/// is a total function of `(agent, payload, now)`. Payloads it does not
/// recognize map to `nil` so the caller can drop them silently.
public enum StageMapper {

    /// Maximum length of ``AgentEvent/detail``, including the ellipsis.
    static let detailLimit = 80

    /// Maps a raw hook payload to an event, or nil for events Notch ignores.
    public static func map(agent: Agent, payload: [String: Any], now: Date) -> AgentEvent? {
        switch agent {
        case .claude: mapClaude(payload, now: now)
        case .codex: mapCodex(payload, now: now)
        case .cursor: mapCursor(payload, now: now)
        }
    }

    // MARK: - Claude Code

    private static let claudeCreatingTools: Set<String> = [
        "Edit", "Write", "MultiEdit", "Bash", "NotebookEdit",
    ]
    private static let claudeAnalyzingTools: Set<String> = [
        "Read", "Grep", "Glob", "Agent", "Explore", "WebFetch", "WebSearch", "LSP",
    ]
    /// `Notification.notification_type` values that mean "the agent needs you".
    private static let claudeWaitingNotifications: Set<String> = [
        "permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog",
    ]

    private static func mapClaude(_ payload: [String: Any], now: Date) -> AgentEvent? {
        guard let event = string(payload, "hook_event_name") else { return nil }
        let tool = string(payload, "tool_name")
        let session = string(payload, "session_id") ?? unknownSession
        let sourceApp = string(payload, "sourceApp")

        func make(_ stage: Stage, tool: String? = nil, detail: String? = nil) -> AgentEvent {
            AgentEvent(
                agent: .claude,
                sessionID: session,
                stage: stage,
                tool: tool,
                detail: detail,
                sourceApp: sourceApp,
                timestamp: now
            )
        }

        switch event {
        case "UserPromptSubmit":
            return make(.thinking)
        case "PreToolUse":
            let stage: Stage =
                if let tool, claudeCreatingTools.contains(tool) { .creating }
                else if let tool, claudeAnalyzingTools.contains(tool) { .analyzing }
                else { .thinking }
            return make(stage, tool: tool)
        case "PostToolUse":
            return make(.thinking, tool: tool)
        case "PermissionRequest":
            return make(.waiting, tool: tool, detail: permissionDetail(payload, tool: tool))
        case "Notification":
            let type = string(payload, "notification_type")
            let message = truncate(string(payload, "message"))
            if let type, claudeWaitingNotifications.contains(type) {
                return make(.waiting, detail: message)
            }
            if type == "agent_completed" {
                return make(.completed, detail: message)
            }
            return nil
        case "Stop":
            if bool(payload, "stop_hook_active") { return nil }
            return make(.completed)
        case "SessionEnd":
            return make(.completed)
        default:
            return nil
        }
    }

    /// "<tool>: <command | file_path | first string value>", truncated.
    private static func permissionDetail(_ payload: [String: Any], tool: String?) -> String? {
        guard let tool else { return nil }
        guard let input = payload["tool_input"] as? [String: Any] else { return truncate(tool) }
        let argument = string(input, "command")
            ?? string(input, "file_path")
            ?? firstStringValue(input)
        guard let argument, !argument.isEmpty else { return truncate(tool) }
        return truncate("\(tool): \(argument)")
    }

    /// Dictionaries are unordered, so pick the first string value by sorted key
    /// to keep the mapping deterministic.
    private static func firstStringValue(_ input: [String: Any]) -> String? {
        for key in input.keys.sorted() {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Codex

    private static let codexCreatingTools: Set<String> = ["apply_patch", "shell", "exec_command"]
    private static let codexAnalyzingTools: Set<String> = ["read_file", "view_image", "list_dir"]

    private static func mapCodex(_ payload: [String: Any], now: Date) -> AgentEvent? {
        // Newer [hooks] payloads carry `hook_event_name`; the legacy notify
        // payload carries `type`.
        guard let event = string(payload, "hook_event_name") ?? string(payload, "type") else { return nil }
        let tool = string(payload, "tool_name")
        let session = string(payload, "session_id") ?? string(payload, "thread-id") ?? unknownSession

        func make(_ stage: Stage, tool: String? = nil, detail: String? = nil) -> AgentEvent {
            AgentEvent(
                agent: .codex,
                sessionID: session,
                stage: stage,
                tool: tool,
                detail: detail,
                sourceApp: "codex",
                timestamp: now
            )
        }

        switch event {
        case "UserPromptSubmit":
            return make(.thinking)
        case "PreToolUse":
            let stage: Stage =
                if let tool, codexCreatingTools.contains(tool) { .creating }
                else if let tool, codexAnalyzingTools.contains(tool) { .analyzing }
                else { .thinking }
            return make(stage, tool: tool)
        case "PostToolUse":
            return make(.thinking, tool: tool)
        case "Stop", "agent-turn-complete":
            let last = string(payload, "last_assistant_message") ?? string(payload, "last-assistant-message")
            return make(.completed, detail: truncate(last))
        default:
            return nil
        }
    }

    // MARK: - Cursor

    private static let cursorCreatingTools: Set<String> = [
        "Shell", "Edit", "Write", "MultiEdit", "apply_patch",
    ]
    private static let cursorAnalyzingTools: Set<String> = [
        "Read", "Search", "Grep", "Glob", "List", "Codebase",
    ]

    private static func mapCursor(_ payload: [String: Any], now: Date) -> AgentEvent? {
        guard let event = string(payload, "hook_event_name") else { return nil }
        let tool = string(payload, "tool_name")
        let session = string(payload, "conversation_id") ?? unknownSession

        func make(_ stage: Stage, tool: String? = nil) -> AgentEvent {
            AgentEvent(
                agent: .cursor,
                sessionID: session,
                stage: stage,
                tool: tool,
                detail: nil,
                sourceApp: "cursor",
                timestamp: now
            )
        }

        switch event {
        case "beforeSubmitPrompt":
            return make(.thinking)
        case "afterFileEdit":
            return make(.creating)
        case "preToolUse":
            let stage: Stage =
                if let tool, cursorCreatingTools.contains(tool) { .creating }
                else if let tool, cursorAnalyzingTools.contains(tool) { .analyzing }
                else { .thinking }
            return make(stage, tool: tool)
        case "postToolUse":
            return make(.thinking, tool: tool)
        case "stop":
            // status is completed, aborted or error: only a real error is a
            // failure, an aborted turn is the user stopping the agent.
            return make(string(payload, "status") == "error" ? .failed : .completed)
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static let unknownSession = "unknown"

    private static func string(_ payload: [String: Any], _ key: String) -> String? {
        guard let value = payload[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func bool(_ payload: [String: Any], _ key: String) -> Bool {
        if let value = payload[key] as? Bool { return value }
        if let value = payload[key] as? NSNumber { return value.boolValue }
        return false
    }

    /// Clamps to ``detailLimit`` characters, ellipsis included.
    private static func truncate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.count > detailLimit else { return value }
        return String(value.prefix(detailLimit - 1)) + "…"
    }
}
