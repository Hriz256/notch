# Notch — Sub-project 2: Coding Agent

**Date:** 2026-09-12
**Status:** approved (user waived per-section review: "мне нужен результат как в оригинале")
**Reference:** Seam 1.14.7 "Code" feature. Research: `research/coding-agent-mechanics.md`, `research/seam-analysis.md`, user photos of Seam's island (compact: pixel Claude icon left + salmon progress ring right; expanded: icon, coffee cup, two bars "8% session · Resets 4h 18m ● You're good" / "36% weekly · Resets 6d 13h ● Slow down", sparkline "Last 7 days").

## 1. Goal

Show what Claude Code, Codex CLI and Cursor agents are doing, right in the notch, and how much of the plan quota they have used — looking and behaving like Seam's Code feature, with three deliberate improvements: a compiled hook helper instead of `osascript` (no per-tool-call latency), instant "waiting for you" alerts from Claude Code's `PermissionRequest` hook, and a correct `User-Agent` on the usage API.

## 2. Decisions

| Topic | Decision |
|---|---|
| Agents | Claude Code, Codex CLI, Cursor. Each individually enabled; Codex/Cursor only offered when installed (`~/.codex`, `/Applications/Cursor.app`). |
| Event transport | Hook command = bundled CLI `notch-hook <agent>` (reads stdin JSON, posts `NSDistributedNotificationCenter` notification `app.notch.agent.event`, exits 0 always, never blocks > 1 s). Stage mapping lives in Swift in the app. |
| Hook installation | Automatic, marked `managed by Notch`, idempotent, removed on disable. Existing Seam-managed hooks are replaced (their command path contains `.seam/hooks`). Codex additionally needs the user to approve hooks via `/hooks` in Codex; the island shows a one-time hint. |
| Usage sources | Claude: Keychain `Claude Code-credentials` → `GET https://api.anthropic.com/api/oauth/usage` (headers `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<installed version>`; fall back to `~/.claude/.credentials.json`). No token refresh (Claude Code owns it). Codex: `codex app-server` JSON-RPC `account/rateLimits/read`. Cursor: token from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`cursorAuth/accessToken`), `https://cursor.com/api/usage?user=<sub>` (usage counts) — best effort. |
| Sparkline | Claude: hourly token buckets from `~/.claude/projects/**/*.jsonl` (`type == "assistant"`, `message.usage.*`, dedup by `message.id:requestId`), cached in `~/Library/Application Support/Notch/claude-usage-cache.json` keyed by file path + mtime. Codex/Cursor: no sparkline in this sub-project (flat placeholder). |
| Pace indicator | `used% > elapsed% of window + 10` → "Slow down" (red); otherwise "You're good" (green). |
| Polling | Usage: every 5 min while a session is active, 15 min idle, once at each window's `resets_at`, once on wake; 429 → backoff 5 → 60 min. Sparkline: rescan on `Stop`/`completed` events and every 10 min. |
| Alerts | Completed → 4 s peek with check glyph + chime (system sound "Glass"; setting). Failed → 4 s peek, red. Waiting for you (`PermissionRequest`, `Notification` idle/permission, `agent_needs_input`) → sticky `.alert` peek (amber) until the next event from that session. |
| Caffeinate | Optional: `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` while any session is active; released when all sessions end. Coffee-cup glyph top-right of the expanded view toggles it; filled when active. |
| Settings (status menu + right-click context menu on the island) | Per agent: enabled; stages to show (Analyzing / Thinking / Creating); show when idle. Global: completion sound, pace indicator, caffeinate, "current agent" for usage display. Keys `code.<agent>.enabled`, `code.<agent>.showAnalyzing/Thinking/Creating`, `code.<agent>.showWhenIdle`, `code.playCompleteSound`, `code.showPace`, `code.caffeinate`, `code.currentAgent`. |
| Not in scope | Cursor sparkline, Codex sparkline, "show overlay when code app is focused", caffeine "dance" animation, settings window. |

## 3. Architecture

```
NotchKit
├── CodeAgentShared      Agent enum, AgentEvent, Stage, StageMapper (pure), HookConfigEditor (pure string transforms), UsageModels
├── CodeAgentFeature     HookInstaller, EventReceiver, SessionTracker, UsageProviders, Caffeinator, CodeAgentViewModel, views
notch-hook (CLI target, Contents/MacOS/notch-hook)   stdin JSON → distributed notification
```

`CodeAgentFeature: IslandFeature` registers as `FeatureID("code")`. It never imports `MusicFeature`.

### 3.1 CodeAgentShared

```swift
public enum Agent: String, CaseIterable, Codable, Sendable { case claude, codex, cursor }

public enum Stage: String, Codable, Sendable { case analyzing, thinking, creating, waiting, completed, failed }

public struct AgentEvent: Codable, Sendable, Equatable {
    public var agent: Agent
    public var sessionID: String
    public var stage: Stage
    public var tool: String?          // "Edit", "Bash", "apply_patch"…
    public var detail: String?        // permission message, last assistant line (≤ 80 chars)
    public var sourceApp: String?     // TERM_PROGRAM / "cursor"
    public var timestamp: Date
}

public enum StageMapper {
    /// Pure mapping from raw hook JSON (already parsed) to an event. Returns nil for events we ignore.
    public static func map(agent: Agent, payload: [String: Any], now: Date) -> AgentEvent?
}
```

Mapping (Claude Code): `UserPromptSubmit` → thinking; `PreToolUse` → Edit/Write/MultiEdit/Bash/NotebookEdit → creating, Read/Grep/Glob/Agent/Explore/WebFetch/WebSearch/LSP → analyzing, else thinking (tool name kept); `PostToolUse` → thinking; `PermissionRequest` → waiting (tool + `tool_input.command` first 80 chars as detail); `Notification` with `notification_type` in {permission_prompt, idle_prompt, agent_needs_input, elicitation_dialog} → waiting, `agent_completed` → completed; `Stop` → completed (unless `stop_hook_active`, or with in-flight `background_tasks` → thinking); `SessionEnd` → ended (the chat was closed: the tracker drops the session, no alert). Codex: `UserPromptSubmit` → thinking; `PreToolUse` apply_patch/shell/exec_command → creating, read_file/view_image/list_dir → analyzing, else thinking; `PostToolUse` → thinking; `Stop`/`agent-turn-complete` → completed (detail = `last_assistant_message`/`last-assistant-message` ≤ 80). Cursor: `beforeSubmitPrompt` → thinking; `afterFileEdit` → creating; `preToolUse` Shell/Edit/Write/MultiEdit/apply_patch → creating, Read/Search/Grep/Glob/List/Codebase → analyzing; `postToolUse` → thinking; `stop` status error → failed, else completed.

```swift
public enum HookConfigEditor {
    public static let marker = "managed by Notch"
    /// settings.json: insert/replace a Notch hook entry for each of the events; remove Seam entries (command contains ".seam/hooks"). Preserves unrelated keys byte-for-byte where JSON round-trip allows.
    public static func installClaude(settingsJSON: String, command: String) throws -> String
    public static func removeClaude(settingsJSON: String) throws -> String
    /// config.toml: a fenced block `# === managed by Notch (begin) === … (end) ===` with [[hooks.X]] tables; Seam's block (`managed by Seam.app`) is removed.
    public static func installCodex(configTOML: String, command: String) -> String
    public static func removeCodex(configTOML: String) -> String
    /// hooks.json (version 1): same idea as Claude.
    public static func installCursor(hooksJSON: String, command: String) throws -> String
    public static func removeCursor(hooksJSON: String) throws -> String
}
```

Claude events installed: `UserPromptSubmit`, `PreToolUse` (matcher ""), `PostToolUse` (""), `PermissionRequest` (""), `Notification`, `Stop`, `SessionEnd`. Codex: `UserPromptSubmit`, `PreToolUse` (matcher "*"), `PostToolUse` ("*"), `Stop`. Cursor: `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `afterFileEdit`, `stop` (timeout 5).

```swift
public struct UsageWindow: Codable, Sendable, Equatable { public var percent: Double; public var resetsAt: Date? }
public struct AgentUsage: Codable, Sendable, Equatable {
    public var agent: Agent
    public var session: UsageWindow?     // Claude five_hour; Codex primary; Cursor: requests used/limit
    public var weekly: UsageWindow?      // Claude seven_day; Codex secondary
    public var sparkline: [Double]       // 7 daily totals (tokens), oldest first; empty if unavailable
    public var fetchedAt: Date
    public var planLabel: String?        // "Max", "Pro", "plus"…
}
public enum Pace { case good, slowDown }
public enum PaceCalculator {
    /// windowLength: 5h or 7d. `now` vs `resetsAt` gives elapsed fraction.
    public static func pace(percent: Double, resetsAt: Date?, windowLength: TimeInterval, now: Date) -> Pace?
}
public enum ResetFormatter { public static func string(until: Date, now: Date) -> String }  // "4h 18m", "6d 13h", "12m"
```

### 3.2 notch-hook CLI

Swift executable target `notch-hook`, product copied into `Notch.app/Contents/MacOS/`. Usage: `notch-hook claude|codex|cursor`. Reads all of stdin (max 64 KB; if larger, keeps the first 64 KB), or `$1`-after-agent for Codex legacy notify. Posts `NSDistributedNotificationCenter.default().postNotificationName("app.notch.agent.event", object: nil, userInfo: ["agent": agent, "payload": jsonString], deliverImmediately: true)`. Truncates `tool_input`/`message` values > 2 KB before posting. Always exits 0; total runtime target < 20 ms. No Foundation networking.

### 3.3 CodeAgentFeature

- **HookInstaller** (`@MainActor`): `install(agent:)`/`uninstall(agent:)` read the config file, run the pure editor, write atomically, keep a `.bak` once. Command path = `Bundle.main.bundleURL/Contents/MacOS/notch-hook <agent>`. On app launch, if an installed command path differs from the current bundle path (app moved), re-install. Logs and surfaces errors via `installState[agent]`.
- **EventReceiver**: observes the distributed notification, parses payload with `JSONSerialization`, calls `StageMapper.map`, forwards events on the main actor.
- **SessionTracker** (`@Observable`): `sessions: [SessionID: Session]` with `agent, stage, tool, detail, startedAt, lastEventAt`; `activeSession` = most recent `lastEventAt` among non-completed; completed sessions are kept for 60 s (for the alert), abandoned after 30 min without events. `activeCount`.
- **UsageProviders**: `protocol UsageProvider { agent; func fetch() async throws -> AgentUsage }` with `ClaudeUsageProvider` (Keychain via `SecItemCopyMatching` for service `Claude Code-credentials`, then `/api/oauth/usage`, parse `five_hour`/`seven_day` (nullable) preferring `limits[]` entries `session`/`weekly_all` when present; version from `claude --version` or `~/.claude/...`; fallback UA `claude-code/2.1.0`), `CodexUsageProvider` (spawn `codex app-server`, JSON-RPC `initialize` then `account/rateLimits/read`, camelCase fields, 10 s timeout), `CursorUsageProvider` (sqlite3 via `/usr/bin/sqlite3` read of `state.vscdb`, `GET https://cursor.com/api/usage?user=<sub>` with cookie `WorkosCursorSessionToken=<sub>::<token>`; best effort, errors → "Sign in to Cursor"). `UsageRefreshCoordinator` schedules per the polling table; results in `usage: [Agent: Result<AgentUsage, UsageError>]`.
- **ClaudeSparkline**: scans jsonl files with mtime caching; produces 7 daily totals ending today.
- **Caffeinator**: IOPM assertion on/off; observable `isActive`.
- **CodeAgentViewModel** (`@MainActor @Observable`): combines tracker + usage + settings into island presentations:
  - Idle (no active sessions): if `showWhenIdle` for the current agent and usage available → sticky `.background` `.peek`: leading = agent icon, trailing = `SessionRing(percent)`; expanded = usage panel.
  - Working: sticky `.activity` `.peek` (replaces idle presentation in place, same id): leading = agent icon (pulsing while thinking), trailing = stage glyph + tool name abbreviation (e.g. "Edit"); expanded = activity panel (stage, tool, detail, elapsed since `startedAt`, session count) with the usage bars beneath.
  - Waiting: `.alert` `.peek`, amber; trailing = "hand.raised" glyph; expanded shows the request text.
  - Completed / Failed: `.alert` peek with `checkmark` (green) / `xmark` (red) for 4 s, plus chime if enabled and completed.
  - Stage filters: stages the user disabled do not change the visible stage (the previous shown stage persists).
- **Views**: `AgentIcon` (Claude: 10×8 pixel sprite in salmon `#F5A08A`-like drawn with `Canvas`; Codex: SF `terminal.fill` white; Cursor: SF `cursorarrow.rays` white), `SessionRing` (2 pt stroke, salmon, 14 pt), `UsageBarRow` (label "8% session" left, "Resets 4h 18m" + pace dot/label right; bar 4 pt, salmon fill, 8 % white track), `SparklineView` (smooth line + gradient fill, "Last 7 days" caption), `CodeExpandedView` (380×170: header [icon … coffee cup], two `UsageBarRow`, sparkline), `CodeActivityView` (header [icon, stage glyph, stage title, tool], detail line, elapsed, then the two bars), `CodeContextMenu` (`.contextMenu` on the expanded view and on the compact island: pick agent, caffeinate, sound, refresh usage, install/uninstall hooks per agent).

### 3.4 App wiring

- `AppCoordinator.start()` registers `CodeAgentFeature()` after `MusicFeature()`.
- Status menu gains a "Coding agents" submenu mirroring the settings.
- Priority interplay with Music: code `.activity` outranks music `.background`; code `.alert` outranks both. When code is idle and `showWhenIdle` is off, music's island shows.

## 4. Error handling

| Failure | Behavior |
|---|---|
| Config file missing | Create minimal valid file (`{}` / empty TOML / `{"version":1,"hooks":{}}`). |
| Config unparsable | Do not touch; `installState = .failed(reason)`; menu shows "⚠︎ fix ~/.claude/settings.json". |
| Keychain item missing / token expired | Usage shows "Open Claude Code to sign in"; retry every 15 min. |
| Usage 429 / network | Keep last value with "stale" dot; backoff. |
| `codex app-server` missing | Codex usage row "Codex CLI not found". |
| Hook payload malformed | Ignored, logged at debug. |
| Distributed notification burst | Events coalesced on the main actor; UI updates at most 10/s. |

## 5. Idle cost

No timers while no session is active except the usage poll (15 min) and the sparkline rescan (10 min, skipped when no jsonl mtime changed). Pulsing icon animation exists only inside presentation views.

## 6. Tests

Unit: `StageMapperTests` (every mapping row for all three agents, `stop_hook_active`, Cursor error status, truncation), `HookConfigEditorTests` (install → remove round-trip returns original; Seam block removal; idempotent double install; unrelated keys preserved; unparsable input throws), `SessionTrackerTests` (active selection, completion retention, abandonment timeout, counts), `PaceCalculatorTests`, `ResetFormatterTests`, `ClaudeUsageParserTests` (real sample JSON from research, all-null sample, `limits[]` preference), `CodexRateLimitParserTests` (camelCase sample), `ClaudeSparklineTests` (bucketing + dedup on fixture jsonl), `CodeAgentViewModelTests` (presentations per state with FakePresenter/ManualClock; stage filter; sound trigger; alert TTL).
CLI: `notch-hook` smoke test in the plan (pipe JSON, observe notification with a small observer script).
Manual: run a Claude Code task → stages visible; permission prompt → amber alert instantly; completion → chime; right-click → switch to Codex; usage bars match claude.ai's Usage page.
