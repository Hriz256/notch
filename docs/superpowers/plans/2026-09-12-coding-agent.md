# Coding Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Code" island that shows live Claude Code / Codex / Cursor activity, "waiting for you" alerts, completion chimes and plan-usage statistics, looking like Seam's Code feature; plus swipe/context-menu switching between island cards.

**Architecture:** Two new NotchKit modules — `CodeAgentShared` (pure, testable: models, stage mapping, config editing, usage parsing, pace/reset formatting) and `CodeAgentFeature` (hook installer, distributed-notification receiver, session tracker, usage providers, caffeinator, view model, views) — plus a tiny `notch-hook` CLI target bundled in the app. `IslandCore` gains manual card switching (cycle) and a scroll-gesture hook.

**Tech Stack:** Swift 6.3 (Xcode 26.6), SwiftUI + AppKit, Swift Testing, XcodeGen, `xcodebuild`, `swift test`. Spec: `docs/superpowers/specs/2026-09-12-coding-agent-design.md`. Research: `research/coding-agent-mechanics.md` (hook payloads, API shapes, real samples).

## Global Constraints

- macOS 26.0 deployment target; Swift language mode 6, strict concurrency complete; no `@unchecked Sendable` without a one-line justification; no `print` in shipped code (the CLI may write to stderr only on `--debug`); logging via `os.Logger(subsystem: "app.notch", category: "code.*")`.
- Feature id `FeatureID("code")`. Settings keys exactly as in spec §2. Notification name `app.notch.agent.event`, userInfo keys `agent`, `payload`.
- Hook command path: `<Bundle.main.bundleURL>/Contents/MacOS/notch-hook <agent>`. Managed marker text `managed by Notch`. Seam hooks (command containing `.seam/hooks`, TOML block `managed by Seam.app`) are removed on install.
- Claude usage request headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>`, `Accept: application/json`. Never refresh the token. Never log token values.
- Idle rule (spec §5). Expanded island size for code views: 380×170.
- Verification per task: `cd NotchKit && swift test 2>&1 | tail -5` green and pristine; `xcodegen generate >/dev/null && xcodebuild -project Notch.xcodeproj -scheme Notch -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error|warning: |BUILD" | head` → `** BUILD SUCCEEDED **`. Commit each task; messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Work on branch `feature/coding-agent`.
- Agents implementing tasks must not modify `~/.claude/settings.json`, `~/.codex/config.toml` or `~/.cursor/hooks.json` themselves; only unit tests on string fixtures. Installing hooks for real happens when the user enables the feature.

---

## File Structure

```
NotchKit/Sources/CodeAgentShared/
  Agent.swift                Agent, Stage, AgentEvent
  StageMapper.swift          pure mapping from hook JSON
  HookConfigEditor.swift     JSON/TOML managed-block editing (pure)
  UsageModels.swift          UsageWindow, AgentUsage, UsageError, Pace, PaceCalculator, ResetFormatter
  ClaudeUsageParser.swift    /api/oauth/usage JSON → AgentUsage
  CodexRateLimitParser.swift app-server JSON → AgentUsage
  ClaudeUsageLog.swift       jsonl line parsing + daily bucketing (pure)
NotchKit/Sources/CodeAgentFeature/
  CodeAgentFeature.swift     IslandFeature wiring
  Settings/CodeSettings.swift            UserDefaults-backed settings (observable)
  Hooks/HookInstaller.swift
  Events/EventReceiver.swift
  Events/SessionTracker.swift
  Usage/UsageProvider.swift              protocol + UsageRefreshCoordinator
  Usage/ClaudeCredentials.swift          Keychain/file read
  Usage/ClaudeUsageProvider.swift
  Usage/CodexUsageProvider.swift         app-server subprocess
  Usage/CursorUsageProvider.swift
  Usage/ClaudeSparkline.swift            file scan + cache
  Power/Caffeinator.swift
  CodeAgentViewModel.swift
  Views/AgentIcon.swift, SessionRing.swift, UsageBarRow.swift, SparklineView.swift,
        CodeCompactViews.swift, CodeExpandedView.swift, CodeActivityView.swift, CodeContextMenu.swift
HookCLI/main.swift                        notch-hook executable
NotchKit/Sources/IslandCore/Presenter/IslandPresenter.swift   + cycle()/stack
NotchKit/Sources/IslandCore/Surface/SurfaceView.swift          + scroll gesture, stack dots
App/AppCoordinator.swift, App/StatusMenu.swift                 registration + menu
Tests: NotchKit/Tests/CodeAgentSharedTests/*, NotchKit/Tests/CodeAgentFeatureTests/*, IslandCoreTests additions
```

---

### Task 1: Modules, CLI target, models

**Files:** `NotchKit/Package.swift` (add `CodeAgentShared`, `CodeAgentFeature` targets + test targets; `CodeAgentFeature` depends on `IslandCore`, `CodeAgentShared`), `project.yml` (new target `NotchHook`: `type: tool`, `sources: [HookCLI]`, product name `notch-hook`, copied into the app via a `Copy Files` build phase to `$(CONTENTS_FOLDER_PATH)/MacOS` — in XcodeGen: dependency `{ target: NotchHook, embed: true, copy: { destination: executables } }`; app depends on both new package products), `HookCLI/main.swift` (placeholder that exits 0), `NotchKit/Sources/CodeAgentShared/Agent.swift`, `NotchKit/Sources/CodeAgentFeature/CodeAgentFeature.swift` (placeholder feature that does nothing), tests placeholders.

**Interfaces produced:** `Agent`, `Stage`, `AgentEvent` exactly as spec §3.1 (Codable, Sendable, Equatable; `Stage` also `Comparable` by display order analyzing < thinking < creating < waiting < completed < failed is NOT needed — keep plain).

- [ ] Add targets, models, placeholders; `swift test` green; xcodegen + build green; verify `ls build/Build/Products/Debug/Notch.app/Contents/MacOS/` contains `notch-hook`.
- [ ] Commit `chore: add CodeAgentShared/CodeAgentFeature modules and notch-hook CLI target`.

### Task 2: StageMapper (TDD)

**Files:** `NotchKit/Sources/CodeAgentShared/StageMapper.swift`, `NotchKit/Tests/CodeAgentSharedTests/StageMapperTests.swift`.

**Interface:** `public enum StageMapper { public static func map(agent: Agent, payload: [String: Any], now: Date) -> AgentEvent? }` implementing every row of spec §3.1 mapping. Session id: Claude `session_id`, Codex `session_id` or `thread-id`, Cursor `conversation_id`; fallback `"unknown"`. `detail` truncated to 80 characters. `sourceApp`: Claude from payload `"sourceApp"` if the CLI injected it (see Task 4), Codex `"codex"`, Cursor `"cursor"`.

- [ ] Tests (one `@Test` per row, plus): Claude `PreToolUse Edit` → creating tool "Edit"; `PreToolUse Read` → analyzing; `PreToolUse WebSearch` → analyzing; `PreToolUse TodoWrite` → thinking; `PostToolUse` → thinking; `PermissionRequest` with `tool_input.command = "rm -rf build"` → waiting, detail "Bash: rm -rf build"; `Notification permission_prompt` → waiting with `message`; `Notification agent_completed` → completed; `Notification auth_success` → nil; `Stop` → completed; `Stop` with `stop_hook_active: true` → nil; `SessionEnd` → completed; unknown event → nil. Codex: `apply_patch` → creating; `read_file` → analyzing; `agent-turn-complete` with `last-assistant-message` 200 chars → completed with 80-char detail; `type` key fallback. Cursor: `afterFileEdit` → creating; `preToolUse Search` → analyzing; `stop status error` → failed; `stop status aborted` → completed.
- [ ] Implement; tests green; commit `feat(CodeAgentShared): stage mapper for Claude Code, Codex and Cursor hook events`.

### Task 3: HookConfigEditor (TDD)

**Files:** `NotchKit/Sources/CodeAgentShared/HookConfigEditor.swift`, `NotchKit/Tests/CodeAgentSharedTests/HookConfigEditorTests.swift`.

**Interface:** spec §3.1 `HookConfigEditor`. Claude/Cursor use `JSONSerialization` with `.sortedKeys` + `.prettyPrinted` output (accept that whitespace changes; keys preserved). Entry shape for Claude: `{"matcher": "", "hooks": [{"type": "command", "command": "<cmd>", "_notch": "managed by Notch"}]}` under each event array (`_notch` is our marker; Claude Code ignores unknown keys — verify in research; if not allowed, encode the marker in the command string as a trailing `# managed by Notch` comment instead — decide and document). Cursor entry: `{"command": "<cmd>", "timeout": 5, "_notch": "managed by Notch"}`. Codex: text block between `# === managed by Notch (begin) ===` and `# === managed by Notch (end) ===` containing the `[[hooks.X]]` tables from spec; remove any `# === managed by Seam.app - code event hooks (begin) ===` … `(end) ===` block.

- [ ] Tests: install on `{}` produces all events; install twice is idempotent (identical output); remove after install yields no `_notch` entries and keeps a pre-existing user hook untouched; Seam entries (`command` contains `.seam/hooks`) removed on install; unparsable JSON throws; Codex: install on empty string, on a config with other tables (preserved byte-for-byte outside the block), Seam block removed, double install idempotent, remove restores original; Cursor analogous incl. `version: 1` creation.
- [ ] Implement; commit `feat(CodeAgentShared): managed hook config editing for settings.json, config.toml and hooks.json`.

### Task 4: notch-hook CLI

**Files:** `HookCLI/main.swift`.

Behavior (spec §3.2): args `[agent]`; read stdin fully (cap 64 KB); if empty and `CommandLine.arguments.count > 2` use `arguments[2]` (Codex legacy notify); inject `"sourceApp": ProcessInfo.environment["TERM_PROGRAM"]` for Claude when parsing succeeds (re-serialize) — if parsing fails, forward raw text; truncate string values longer than 2 KB inside `tool_input`, `message`, `last_assistant_message`; post `NSDistributedNotificationCenter.default().postNotificationName(Notification.Name("app.notch.agent.event"), object: nil, userInfo: ["agent": agent, "payload": json], deliverImmediately: true)`; exit 0. Wrap everything in a 1 s watchdog (`DispatchQueue.global().asyncAfter { exit(0) }`). Optional `--debug` writes what was posted to stderr.

- [ ] Implement; build; smoke test: write a tiny Swift observer script in the scratchpad that subscribes to the notification and prints userInfo, run it in background, then `echo '{"hook_event_name":"PreToolUse","tool_name":"Edit","session_id":"s1"}' | build/Build/Products/Debug/Notch.app/Contents/MacOS/notch-hook claude`; observer prints the payload. Time it with `time` (< 50 ms).
- [ ] Commit `feat(hook): notch-hook CLI forwarding hook JSON as a distributed notification`.

### Task 5: Usage models, parsers, pace, reset formatter (TDD)

**Files:** `UsageModels.swift`, `ClaudeUsageParser.swift`, `CodexRateLimitParser.swift`, `ClaudeUsageLog.swift` + tests.

**Interfaces:** spec §3.1 `UsageWindow`, `AgentUsage`, `Pace`, `PaceCalculator`, `ResetFormatter`; `public enum UsageError: Error, Equatable { notSignedIn, rateLimited(retryAfter: TimeInterval?), network(String), unavailable(String) }`; `public enum ClaudeUsageParser { static func parse(_ data: Data, now: Date) throws -> AgentUsage }` (prefer `limits[]` `kind == "session"` / `"weekly_all"`; else `five_hour`/`seven_day`; all-null → `AgentUsage` with nil windows); `public enum CodexRateLimitParser { static func parse(_ json: [String: Any], now: Date) -> AgentUsage? }` (camelCase `usedPercent`, `windowDurationMins`, `resetsAt` for `primary`/`secondary`; `planType` → `planLabel`); `public enum ClaudeUsageLog { static func tokens(inLine line: String) -> (key: String?, tokens: Int, timestamp: Date)?; static func dailyTotals(entries: [(key: String?, tokens: Int, timestamp: Date)], days: Int, endingAt: Date, calendar: Calendar) -> [Double] }` with dedup last-write-wins per key.

- [ ] Tests: pace (used 8 % at 15 % elapsed → good; 36 % at 10 % elapsed → slowDown; nil resetsAt → nil); reset formatter ("4h 18m", "6d 13h", "12m", "0m", past → "now"); Claude parser on the September-2026 sample from the research report (48 / 64, resets parsed), the April sample, the all-null Team sample, and a `limits[]`-only sample; Codex parser on the captured app-server response in the research report; usage-log: assistant line with cache tokens sums input+output+cache_creation+cache_read, non-assistant line → nil, duplicates by `message.id:requestId` keep the last, bucketing into 7 days with the calendar's day boundaries.
- [ ] Implement; commit `feat(CodeAgentShared): usage models, Claude/Codex parsers, pace and reset formatting`.

### Task 6: IslandCore — card stack: cycle + scroll gesture + stack dots

**Files:** `IslandPresenter.swift` (+ tests), `SurfaceView.swift`, `SurfaceController.swift` (scroll-wheel monitor), `IslandLayout.swift` (no change unless needed).

**Interfaces:** `IslandPresenter`: `public var stack: [Presentation]` (all queued presentations whose priority < .alert, insertion order), `public private(set) var pinnedID: PresentationID?`, `public func cycle(_ direction: CycleDirection)` (`enum CycleDirection { case next, previous }`) — sets `pinnedID` to the neighbor in `stack`; `current` prefers an `.alert` if any, else the pinned presentation if still queued, else the normal winner; `pinnedID` clears when that presentation is dismissed. `SurfaceController`: local+global `.scrollWheel` monitor: when the pointer is inside the island and a horizontal scroll with |deltaX| ≥ 12 (momentum phase ignored) occurs, call `presenter.cycle(deltaX < 0 ? .next : .previous)`, debounced 400 ms. `SurfaceView`: when `stack.count > 1` and state is `.peek`/`.expanded`, draw `stack.count` 3-pt dots vertically centered on the right edge of the body (outside content, inside the black shape), the current one at full opacity, others 35 %.

- [ ] Tests: cycle with two background presentations pins the other; alert still wins; dismiss of pinned clears the pin; cycle with one presentation is a no-op; `stack` order.
- [ ] Implement, build, commit `feat(IslandCore): manual card switching with two-finger swipe and stack dots`.

### Task 7: CodeAgentFeature — settings, hook installer, event receiver, session tracker (TDD where pure)

**Files:** `Settings/CodeSettings.swift`, `Hooks/HookInstaller.swift`, `Events/EventReceiver.swift`, `Events/SessionTracker.swift` + tests for `SessionTracker` and `HookInstaller` path logic (use a temp directory root injected via `init(homeDirectory:)`).

**Interfaces:** `@MainActor @Observable public final class CodeSettings` (keys spec §2; `isEnabled(agent)`, `showsStage(agent, stage)`, `showWhenIdle(agent)`, `playCompleteSound`, `showPace`, `caffeinate`, `currentAgent`; defaults: Claude enabled true, Codex/Cursor enabled only if installed at first launch, all stages on, showWhenIdle true, sound on, pace on, caffeinate off, currentAgent .claude). `@MainActor public final class HookInstaller { init(homeDirectory: URL, commandBase: URL); var state: [Agent: InstallState]; func install(_:) throws; func uninstall(_:) throws; func reconcile() throws /* re-install where command path differs */ }`, `enum InstallState { notInstalled, installed, failed(String) }`; atomic writes via `Data.write(to:options: .atomic)`; one-time `.notch.bak` copy. `@MainActor public final class EventReceiver { init(onEvent: @escaping (AgentEvent) -> Void); func start(); func stop() }` using `DistributedNotificationCenter.default().addObserver(forName:object:queue:using:)`. `@MainActor @Observable public final class SessionTracker { struct Session { id, agent, stage, tool, detail, startedAt, lastEventAt, isFinished } ; var sessions: [String: Session]; var activeSession: Session?; var activeCount: Int; func handle(_ event: AgentEvent); func prune(now:) }` with retention rules from spec §3.3 and an injected `IslandClock` for the 60 s / 30 min timers.

- [ ] Tests: tracker — first event creates session with startedAt; later event updates stage/tool; completed keeps the session 60 s then removes; 30 min silence abandons; activeSession is the most recent unfinished; activeCount counts unfinished. Installer — install writes the file with the command path, `reconcile` rewrites when commandBase changes, uninstall removes; unparsable file → `.failed` and file untouched.
- [ ] Implement; commit `feat(CodeAgentFeature): settings, hook installer, event receiver and session tracker`.

### Task 8: Usage providers, sparkline scanner, coordinator, caffeinator

**Files:** `Usage/*.swift`, `Power/Caffeinator.swift` + tests for `UsageRefreshCoordinator` scheduling (fake providers, ManualClock) and `ClaudeSparkline` (fixture directory in a temp dir).

**Interfaces:** `public protocol UsageProvider: Sendable { var agent: Agent { get }; func fetch() async throws(UsageError) -> AgentUsage }`; `ClaudeCredentials.load() -> (token: String, expiresAt: Date?)?` via `SecItemCopyMatching` (`kSecClassGenericPassword`, `kSecAttrService = "Claude Code-credentials"`, `kSecReturnData`), falling back to `~/.claude/.credentials.json`; expired (`expiresAt < now`) → `.notSignedIn`. `ClaudeUsageProvider(session: URLSession, version: String)`; version detection: run `claude --version` once (10 s timeout) via `Process` from `/opt/homebrew/bin/claude` or `/usr/local/bin/claude` or `~/.local/bin/claude`, parse the leading semver, else `2.1.0`. `CodexUsageProvider`: `Process` `codex app-server` (paths `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex`), write `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Notch","version":"1.0"}}}` then `{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}` (exact param shapes per research report), read line-delimited responses, 10 s timeout, terminate the process. `CursorUsageProvider`: read token with `/usr/bin/sqlite3 <db> "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"`, decode the JWT payload `sub` (base64url, no verification) for the user id, `GET https://cursor.com/api/usage?user=<sub>` with `Cookie: WorkosCursorSessionToken=<sub>%3A%3A<token>`, parse `gpt-4.numRequests/maxRequestUsage` → session window percent (no weekly), `startOfMonth` → resetsAt + 1 month; any failure → `.unavailable("Sign in to Cursor")`. `ClaudeSparkline(root: URL, cacheURL: URL)`: `func dailyTotals(now:) async -> [Double]` scanning `projects/**/*.jsonl` with a cache `{path: {mtime, entries}}` (entries = parsed `(key, tokens, timestamp)` per file). `@MainActor @Observable final class UsageRefreshCoordinator { init(providers: [any UsageProvider], sparkline: ClaudeSparkline?, clock: any IslandClock, settings: CodeSettings); var usage: [Agent: Result<AgentUsage, UsageError>]; var isSessionActive: Bool { didSet reschedule }; func refreshNow(); func start(); func stop() }` implementing spec §2 polling incl. wake (`NSWorkspace.didWakeNotification`) and per-window `resetsAt` one-shot. `@MainActor final class Caffeinator { var isActive: Bool; func set(_ on: Bool) }` with `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Notch: coding agent working" as CFString, &id)` / `IOPMAssertionRelease`.

- [ ] Tests: coordinator — active → 5 min cadence, idle → 15 min, 429 → backoff, resetsAt one-shot fires, results stored per agent; sparkline — fixture with two files, second scan with unchanged mtime does not re-read (inject a read counter), edited file re-read.
- [ ] Implement; build; commit `feat(CodeAgentFeature): Claude/Codex/Cursor usage providers, sparkline scanner, refresh coordinator, caffeinator`.

### Task 9: View model (TDD)

**Files:** `CodeAgentViewModel.swift`, `NotchKit/Tests/CodeAgentFeatureTests/CodeAgentViewModelTests.swift`.

**Interface:** `@MainActor @Observable public final class CodeAgentViewModel { init(presenter: any IslandPresenting, clock: any IslandClock, settings: CodeSettings, tracker: SessionTracker, usage: UsageRefreshCoordinator, caffeinator: Caffeinator, sound: @escaping () -> Void, viewFactory: CodeViewFactory, now: @escaping @Sendable () -> Date = { Date() }) ; var displayedAgent: Agent; var displayedUsage: AgentUsage?; var usageError: UsageError?; var activeSession: SessionTracker.Session?; var visibleStage: Stage?; var elapsed: TimeInterval; func handle(_ event: AgentEvent); func refreshPresentation(); func selectAgent(_:); func toggleCaffeinate(); func startTicking()/stopTicking() }` and `CodeViewFactory(compactLeading:compactTrailing:expandedIdle:expandedActivity:)` like `MusicViewFactory`. Presentation rules per spec §3.3 (idle sticky `.background` peek only if `showWhenIdle && usage available`; working → same id updated with priority `.activity`; waiting → `.alert` sticky; completed/failed → 4 s `.alert` peek with its own id; stage filter keeps the last shown stage; chime on completed if enabled; caffeinator on while `activeCount > 0 && settings.caffeinate`).

- [ ] Tests (FakePresenter/ManualClock as in MusicFeatureTests): idle with usage → background peek; idle without usage → nothing; event thinking → presentation priority activity; waiting → alert; completed → alert with ttl 4 s then back to idle presentation; stage filter (showThinking false: thinking after creating keeps creating); sound called once on completed only when enabled; caffeinator toggled with sessions; selectAgent changes displayedUsage; `refreshPresentation` after usage result updates in place (same id).
- [ ] Implement; commit `feat(CodeAgentFeature): view model mapping sessions and usage to island presentations`.

### Task 10: Views, context menu, feature wiring, app menu

**Files:** `Views/*.swift`, `CodeAgentFeature.swift` (real), `App/AppCoordinator.swift`, `App/StatusMenu.swift`.

Visual spec (match the Seam photos):
- Compact leading: `AgentIcon` 18 pt. Claude icon = pixel sprite drawn in `Canvas`, 10×8 grid, color `Color(red: 0.96, green: 0.63, blue: 0.54)` (salmon), shape: a friendly blocky creature (row0: cols 1-8; row1: cols 0-9 with eyes as gaps at 2 and 7; row2: 0-9; row3: 1-8; row4: legs at 1-2, 4-5, 7-8) — any coherent 10×8 sprite is fine, document the grid. Codex: SF `terminal.fill` white. Cursor: SF `cursorarrow.rays` white. Pulses (opacity 1 → 0.6, 0.9 s ease-in-out repeat) while stage == thinking.
- Compact trailing: idle → `SessionRing` (14 pt, 2 pt salmon stroke with 25 % track, progress = session percent); working → stage glyph (analyzing `magnifyingglass`, thinking `ellipsis`, creating `pencil.line`, waiting `hand.raised.fill` amber, completed `checkmark` green, failed `xmark` red) 12 pt semibold + abbreviated tool ≤ 6 chars in 10 pt monospaced.
- Expanded idle (`CodeExpandedView`, 380×170 incl. notch pad): header row: `AgentIcon` 18 left, `Spacer`, coffee cup `cup.and.saucer.fill`/`cup.and.saucer` 13 pt (filled when caffeinating, tappable); `UsageBarRow` ×2 with 8 pt spacing: bar 4 pt tall, full width, salmon fill / white 8 % track; below the bar, left label `"8% session"` 12 pt semibold white, right `"Resets 4h 18m"` 11 pt white 55 % + pace dot 6 pt + label ("You're good" green `#48D27A`, "Slow down" red `#FF5B5B`) 11 pt semibold; `SparklineView` 34 pt tall (smooth Catmull-Rom line 1.5 pt salmon + vertical gradient fill salmon 25 % → 0); caption "Last 7 days" 10 pt white 45 %. Errors: replace bars with one line of 11 pt text (e.g. "Open Claude Code to sign in").
- Expanded activity (`CodeActivityView`): header: icon, stage glyph, stage title ("Analyzing" / "Thinking" / "Creating" / "Waiting for you" / "Done" / "Failed") 13 pt semibold, tool name 11 pt 55 %, right: elapsed `m:ss` 11 pt monospaced + "×N" if `activeCount > 1`; detail line (11 pt, 2 lines max, amber when waiting); then the two `UsageBarRow` compact (bar + labels only).
- Context menu (`.contextMenu` on both compact and expanded content): section "Show" with checkmarked agents (enabled ones), "Caffeinate agent" toggle, "Play completion sound" toggle, "Refresh usage", section per agent "Hooks: Installed/Not installed" with Install/Remove.
- `CodeAgentFeature.activate`: build settings, installer (`reconcile()`), receiver, tracker, providers (Codex/Cursor only if installed), coordinator, caffeinator, view model; `deactivate` tears down, keeps hooks installed (uninstall only via settings). Register in `AppCoordinator.start()` after Music. Status menu: "Coding agents" submenu with per-agent enable toggles (enable → install hooks; disable → uninstall), sound/pace/caffeinate toggles.

- [ ] Implement; build; commit `feat(CodeAgentFeature): island views, context menu and app wiring`.

### Task 11: Runtime verification and polish

- [ ] Build, launch, enable Claude in the menu → confirm `~/.claude/settings.json` gained the Notch hooks and Seam's were removed (`grep -c notch-hook ~/.claude/settings.json`), `~/.claude/settings.json.notch.bak` exists.
- [ ] Trigger events without a real session: pipe fixture JSON into `notch-hook claude` for thinking → creating → PermissionRequest → Stop and verify with `log show` (subsystem app.notch, category code.*) that stages arrived and the island presented (human confirms visually).
- [ ] Usage: `log show` shows a successful fetch (percent values logged at info without tokens) or a clear error.
- [ ] Idle audit: with no sessions and usage displayed, `ps` CPU ≈ 0; `docs/superpowers/notes/2026-09-12-code-idle-cost.md`.
- [ ] Commit `chore: coding agent runtime verification notes`.

## Self-review notes
Spec §3.1 → Tasks 1–3, 5; §3.2 → Task 4; §3.3 → Tasks 7–10; §3.4 → Task 10; §4 error handling → Tasks 7, 8, 10; §5 idle → Tasks 8, 9, 11; §6 tests → Tasks 2, 3, 5, 6, 7, 8, 9; card switching (user question) → Task 6.
