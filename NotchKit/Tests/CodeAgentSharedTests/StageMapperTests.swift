import Testing
import Foundation
@testable import CodeAgentShared

private let now = Date(timeIntervalSince1970: 1_757_000_000)

private func claude(_ payload: [String: Any]) -> AgentEvent? {
    StageMapper.map(agent: .claude, payload: payload, now: now)
}

private func codex(_ payload: [String: Any]) -> AgentEvent? {
    StageMapper.map(agent: .codex, payload: payload, now: now)
}

private func cursor(_ payload: [String: Any]) -> AgentEvent? {
    StageMapper.map(agent: .cursor, payload: payload, now: now)
}

@Suite struct StageMapperTests {

    // MARK: - Claude Code

    @Test func claudeUserPromptSubmitIsThinking() {
        let event = claude(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "hi"])
        #expect(event?.stage == .thinking)
        #expect(event?.sessionID == "s1")
        #expect(event?.agent == .claude)
        #expect(event?.timestamp == now)
        #expect(event?.tool == nil)
    }

    @Test func claudePreToolUseEditIsCreating() {
        let event = claude(["hook_event_name": "PreToolUse", "tool_name": "Edit", "session_id": "s1"])
        #expect(event?.stage == .creating)
        #expect(event?.tool == "Edit")
    }

    @Test func claudePreToolUseBashIsCreating() {
        let event = claude(["hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s1"])
        #expect(event?.stage == .creating)
        #expect(event?.tool == "Bash")
    }

    @Test func claudePreToolUseNotebookEditIsCreating() {
        #expect(claude(["hook_event_name": "PreToolUse", "tool_name": "NotebookEdit"])?.stage == .creating)
    }

    @Test func claudePreToolUseReadIsAnalyzing() {
        let event = claude(["hook_event_name": "PreToolUse", "tool_name": "Read", "session_id": "s1"])
        #expect(event?.stage == .analyzing)
        #expect(event?.tool == "Read")
    }

    @Test func claudePreToolUseWebSearchIsAnalyzing() {
        let event = claude(["hook_event_name": "PreToolUse", "tool_name": "WebSearch"])
        #expect(event?.stage == .analyzing)
        #expect(event?.tool == "WebSearch")
    }

    @Test func claudePreToolUseTodoWriteIsThinking() {
        let event = claude(["hook_event_name": "PreToolUse", "tool_name": "TodoWrite"])
        #expect(event?.stage == .thinking)
        #expect(event?.tool == "TodoWrite")
    }

    /// The tool has finished by the time PostToolUse arrives, so the thinking that follows
    /// must not carry its name — the island would otherwise read "Thinking Edit".
    @Test func claudePostToolUseIsThinkingWithoutATool() {
        let event = claude(["hook_event_name": "PostToolUse", "tool_name": "Edit", "session_id": "s1"])
        #expect(event?.stage == .thinking)
        #expect(event?.tool == nil)
    }

    @Test func claudePermissionRequestIsWaitingWithCommandDetail() {
        let event = claude([
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build", "description": "clean"],
            "session_id": "s1",
        ])
        #expect(event?.stage == .waiting)
        #expect(event?.tool == "Bash")
        #expect(event?.detail == "Bash: rm -rf build")
    }

    @Test func claudePermissionRequestFallsBackToFilePath() {
        let event = claude([
            "hook_event_name": "PermissionRequest",
            "tool_name": "Edit",
            "tool_input": ["file_path": "/tmp/a.swift"],
        ])
        #expect(event?.detail == "Edit: /tmp/a.swift")
    }

    @Test func claudePermissionRequestFallsBackToFirstStringValue() {
        let event = claude([
            "hook_event_name": "PermissionRequest",
            "tool_name": "WebFetch",
            "tool_input": ["url": "https://example.com"],
        ])
        #expect(event?.detail == "WebFetch: https://example.com")
    }

    @Test func claudePermissionRequestWithoutUsableInputKeepsToolOnly() {
        let event = claude(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": [String: Any]()])
        #expect(event?.stage == .waiting)
        #expect(event?.detail == "Bash")
    }

    @Test func claudePermissionRequestDetailIsTruncated() {
        let long = String(repeating: "x", count: 200)
        let event = claude([
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": ["command": long],
        ])
        #expect(event?.detail?.count == 80)
        #expect(event?.detail?.hasSuffix("…") == true)
    }

    @Test func claudeNotificationPermissionPromptIsWaitingWithMessage() {
        let event = claude([
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
            "session_id": "s1",
        ])
        #expect(event?.stage == .waiting)
        #expect(event?.detail == "Claude needs your permission to use Bash")
    }

    @Test func claudeNotificationIdlePromptIsWaiting() {
        #expect(claude([
            "hook_event_name": "Notification",
            "notification_type": "idle_prompt",
            "message": "Waiting for your input",
        ])?.stage == .waiting)
    }

    @Test func claudeNotificationAgentNeedsInputIsWaiting() {
        #expect(claude(["hook_event_name": "Notification", "notification_type": "agent_needs_input"])?.stage == .waiting)
    }

    @Test func claudeNotificationElicitationDialogIsWaiting() {
        #expect(claude(["hook_event_name": "Notification", "notification_type": "elicitation_dialog"])?.stage == .waiting)
    }

    @Test func claudeNotificationAgentCompletedIsCompleted() {
        let event = claude([
            "hook_event_name": "Notification",
            "notification_type": "agent_completed",
            "message": "All done",
        ])
        #expect(event?.stage == .completed)
        #expect(event?.detail == "All done")
    }

    @Test func claudeNotificationAuthSuccessIsIgnored() {
        #expect(claude(["hook_event_name": "Notification", "notification_type": "auth_success"]) == nil)
    }

    @Test func claudeStopIsCompleted() {
        let event = claude(["hook_event_name": "Stop", "session_id": "s1", "stop_hook_active": false])
        #expect(event?.stage == .completed)
    }

    @Test func claudeStopWithActiveStopHookIsIgnored() {
        #expect(claude(["hook_event_name": "Stop", "session_id": "s1", "stop_hook_active": true]) == nil)
    }

    @Test func claudeSessionEndIsCompleted() {
        #expect(claude(["hook_event_name": "SessionEnd", "session_id": "s1", "reason": "clear"])?.stage == .completed)
    }

    @Test func claudeUnknownEventIsIgnored() {
        #expect(claude(["hook_event_name": "PreCompact", "session_id": "s1"]) == nil)
    }

    @Test func claudeMissingEventNameIsIgnored() {
        #expect(claude(["session_id": "s1"]) == nil)
    }

    @Test func claudeSessionIDFallsBackToUnknown() {
        #expect(claude(["hook_event_name": "PostToolUse", "tool_name": "Read"])?.sessionID == "unknown")
    }

    @Test func claudeSourceAppComesFromPayload() {
        let event = claude(["hook_event_name": "UserPromptSubmit", "sourceApp": "iTerm.app"])
        #expect(event?.sourceApp == "iTerm.app")
    }

    @Test func claudeSourceAppIsNilWhenAbsent() {
        #expect(claude(["hook_event_name": "UserPromptSubmit"])?.sourceApp == nil)
    }

    // MARK: - Codex

    @Test func codexUserPromptSubmitIsThinking() {
        let event = codex(["hook_event_name": "UserPromptSubmit", "session_id": "c1"])
        #expect(event?.stage == .thinking)
        #expect(event?.agent == .codex)
        #expect(event?.sourceApp == "codex")
    }

    @Test func codexApplyPatchIsCreating() {
        let event = codex(["hook_event_name": "PreToolUse", "tool_name": "apply_patch", "session_id": "c1"])
        #expect(event?.stage == .creating)
        #expect(event?.tool == "apply_patch")
    }

    @Test func codexShellIsCreating() {
        #expect(codex(["hook_event_name": "PreToolUse", "tool_name": "shell"])?.stage == .creating)
    }

    @Test func codexExecCommandIsCreating() {
        #expect(codex(["hook_event_name": "PreToolUse", "tool_name": "exec_command"])?.stage == .creating)
    }

    @Test func codexReadFileIsAnalyzing() {
        let event = codex(["hook_event_name": "PreToolUse", "tool_name": "read_file", "session_id": "c1"])
        #expect(event?.stage == .analyzing)
        #expect(event?.tool == "read_file")
    }

    @Test func codexListDirIsAnalyzing() {
        #expect(codex(["hook_event_name": "PreToolUse", "tool_name": "list_dir"])?.stage == .analyzing)
    }

    @Test func codexUnknownToolIsThinking() {
        let event = codex(["hook_event_name": "PreToolUse", "tool_name": "update_plan"])
        #expect(event?.stage == .thinking)
        #expect(event?.tool == "update_plan")
    }

    @Test func codexPostToolUseIsThinkingWithoutATool() {
        let event = codex(["hook_event_name": "PostToolUse", "tool_name": "shell"])
        #expect(event?.stage == .thinking)
        #expect(event?.tool == nil)
    }

    @Test func codexStopIsCompletedWithLastAssistantMessage() {
        let event = codex([
            "hook_event_name": "Stop",
            "session_id": "c1",
            "last_assistant_message": "Refactored the mapper.",
        ])
        #expect(event?.stage == .completed)
        #expect(event?.detail == "Refactored the mapper.")
    }

    @Test func codexAgentTurnCompleteTruncatesLongMessage() {
        let long = String(repeating: "a", count: 200)
        let event = codex(["type": "agent-turn-complete", "thread-id": "t1", "last-assistant-message": long])
        #expect(event?.stage == .completed)
        #expect(event?.sessionID == "t1")
        #expect(event?.detail?.count == 80)
        #expect(event?.detail == String(repeating: "a", count: 79) + "…")
    }

    @Test func codexFallsBackToTypeKeyForEventName() {
        let event = codex(["type": "PreToolUse", "tool_name": "apply_patch", "session_id": "c1"])
        #expect(event?.stage == .creating)
    }

    @Test func codexSessionIDPrefersSessionIDOverThreadID() {
        let event = codex(["hook_event_name": "PostToolUse", "session_id": "c1", "thread-id": "t1"])
        #expect(event?.sessionID == "c1")
    }

    @Test func codexUnknownEventIsIgnored() {
        #expect(codex(["hook_event_name": "PreCompact", "session_id": "c1"]) == nil)
    }

    // MARK: - Cursor

    @Test func cursorBeforeSubmitPromptIsThinking() {
        let event = cursor(["hook_event_name": "beforeSubmitPrompt", "conversation_id": "u1"])
        #expect(event?.stage == .thinking)
        #expect(event?.sessionID == "u1")
        #expect(event?.sourceApp == "cursor")
    }

    @Test func cursorAfterFileEditIsCreating() {
        let event = cursor([
            "hook_event_name": "afterFileEdit",
            "conversation_id": "u1",
            "file_path": "/tmp/a.swift",
        ])
        #expect(event?.stage == .creating)
        #expect(event?.agent == .cursor)
    }

    @Test func cursorPreToolUseSearchIsAnalyzing() {
        let event = cursor(["hook_event_name": "preToolUse", "tool_name": "Search", "conversation_id": "u1"])
        #expect(event?.stage == .analyzing)
        #expect(event?.tool == "Search")
    }

    @Test func cursorPreToolUseShellIsCreating() {
        let event = cursor(["hook_event_name": "preToolUse", "tool_name": "Shell"])
        #expect(event?.stage == .creating)
        #expect(event?.tool == "Shell")
    }

    @Test func cursorPreToolUseUnknownToolIsThinking() {
        #expect(cursor(["hook_event_name": "preToolUse", "tool_name": "Todo"])?.stage == .thinking)
    }

    @Test func cursorPostToolUseIsThinkingWithoutATool() {
        let event = cursor(["hook_event_name": "postToolUse", "tool_name": "Read"])
        #expect(event?.stage == .thinking)
        #expect(event?.tool == nil)
    }

    @Test func cursorStopWithErrorStatusIsFailed() {
        let event = cursor(["hook_event_name": "stop", "status": "error", "conversation_id": "u1"])
        #expect(event?.stage == .failed)
    }

    @Test func cursorStopWithAbortedStatusIsCompleted() {
        #expect(cursor(["hook_event_name": "stop", "status": "aborted", "conversation_id": "u1"])?.stage == .completed)
    }

    @Test func cursorStopWithCompletedStatusIsCompleted() {
        #expect(cursor(["hook_event_name": "stop", "status": "completed"])?.stage == .completed)
    }

    @Test func cursorUnknownEventIsIgnored() {
        #expect(cursor(["hook_event_name": "workspaceOpen", "conversation_id": "u1"]) == nil)
    }
}
