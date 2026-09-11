# Coding-Agent Island — exact mechanics

Research for Notch's "Coding Agent" island, mirroring Seam's **Code** feature.
Covers (A) live activity via hooks, (B) usage / rate-limit statistics, (C) Seam's UI states, settings and assets.

**Evidence classes used below**

| Tag | Meaning |
|---|---|
| **[disk]** | Read directly from this machine (Seam's installed hooks, `~/.claude`, `~/.codex`, `~/.cursor`, Seam's caches) |
| **[bin]** | `strings` / `nm` over a shipped binary (`/Applications/Seam.app/Contents/MacOS/Seam`, `@anthropic-ai/claude-code/bin/claude.exe`) |
| **[live]** | An RPC/API call actually executed during this research |
| **[docs]** | Vendor documentation |
| **[oss]** | Open-source implementation |
| *(inference)* | My reading of the evidence, not a literal source |

Local versions at time of writing: **Claude Code 2.1.258** (session transcripts show 2.1.260), **codex-cli 0.146.0**, macOS 26.5.2, Seam 1.14.7.

---

## 0. Executive summary

* Seam's activity transport is **`NSDistributedNotificationCenter`**, posted from a `#!/bin/bash` shim that pipes the hook's stdin JSON into `osascript -l JavaScript`. Three notification names: `app.seam.claudecode.event`, `app.seam.codex.event`, `app.seam.cursor.event`. `userInfo` = `{stage, message, sessionID, sourceApp}`. **[disk]**
* Seam only subscribes to four Claude Code events (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`). Claude Code 2.1.258 actually exposes **33** hook events, including `PermissionRequest` and `Notification` — which is how Notch can beat Seam at "the agent is waiting for you". **[bin] [docs]**
* Usage comes from four different places per agent: an OAuth HTTP API (Claude), a JSON-RPC app-server (Codex), a cookie-authed web API (Cursor), plus local JSONL token scanning for sparklines.
* "Caffeinate" is `IOPMAssertionCreateWithName` with type `PreventUserIdleSystemSleep` — **not** the `caffeinate(8)` binary. **[bin]**

---

## 1. Claude Code hooks

### 1.1 Full event list (v2.1.258)

Extracted from the shipped binary — this is the literal array the CLI validates settings against:

```js
// strings @anthropic-ai/claude-code/bin/claude.exe   [bin]
Hh=["PreToolUse","PostToolUse","PostToolUseFailure","PostToolBatch","Notification",
    "UserPromptSubmit","UserPromptExpansion","SessionStart","SessionEnd","Stop","StopFailure",
    "SubagentStart","SubagentStop","PreCompact","PostCompact","PreModelSwitch","PostModelSwitch",
    "PermissionRequest","PermissionDenied","Setup","TeammateIdle","TaskCreated","TaskCompleted",
    "Elicitation","ElicitationResult","ConfigChange","WorktreeCreate","WorktreeRemove",
    "InstructionsLoaded","CwdChanged","FileChanged","DirectoryAdded","MessageDisplay"]
```

33 events. The public reference at <https://code.claude.com/docs/en/hooks> lists the same set **[docs]**.
(`docs.claude.com/en/docs/claude-code/hooks` now 301-redirects to `code.claude.com/docs/en/hooks`; append `.md` for raw markdown.)

A second binary set gates which events require the advanced-hooks capability:

```js
var Dhe=new Set(["Notification","SessionStart","SessionEnd","Setup","StopFailure","SubagentStart",
  "PostToolUseFailure","PostCompact","PostModelSwitch","PermissionDenied","WorktreeCreate",
  "WorktreeRemove","InstructionsLoaded","CwdChanged","FileChanged","DirectoryAdded",
  "MessageDisplay","StatusLine","FileSuggestion"]);   // [bin]
```

### 1.2 Common stdin fields

The zod base schema, verbatim from the binary **[bin]**:

```js
c({session_id:i(), transcript_path:i(), cwd:i(),
   prompt_id:i().optional().describe("UUID correlating a user prompt with all subsequent events until the next prompt…"),
   permission_mode:i().optional(),
   agent_id:i().optional().describe("Subagent identifier. Present only when the hook fires from within a subagent…"),
   agent_type:i().optional().describe('Agent type name (e.g., "general-purpose", "code-reviewer")…')})
```

Docs add `scratchpad_dir` (v2.1.257+) and `effort: {level}` **[docs]**. `permission_mode` ∈ `default | plan | acceptEdits | auto | dontAsk | bypassPermissions`.

### 1.3 Per-event payloads (the ones that matter for an island)

```js
// [bin] — literal schema fragments
hook_event_name:x("UserPromptSubmit"), prompt:i(),
  source:ee(["user","sdk","system","loop_wakeup","schedule_wakeup","poll_event"]).optional()

hook_event_name:x("PreToolUse"), tool_name:i(), tool_input:de(), tool_use_id:i()

hook_event_name:x("PostToolUse"), tool_name:i(), tool_input:de(), tool_response:de(),
  tool_use_id:i(), duration_ms:A().optional()
      .describe("Tool execution time in milliseconds. Excludes permission-prompt and hook time.")

hook_event_name:x("PermissionRequest"), tool_name:i(), tool_input:de(),
  permission_suggestions:R(_i()).optional()

hook_event_name:x("Notification"), message:i(), title:i().optional(), notification_type:i()

hook_event_name:x("Stop"), stop_hook_active:M(),
  last_assistant_message:i().optional()
      .describe("Text content of the last assistant message before stopping…"),
  background_tasks:R(WL()).optional()

hook_event_name:x("SessionStart"), source:ee(["startup","resume","clear","compact","fork"]),
  agent_type:i().optional(), model:i().optional(), session_title:i().optional(),
  seconds_since_last_response:A().optional(), context_tokens:A().optional()

hook_event_name:x("SessionEnd"), reason:Aoe()     // clear|resume|logout|prompt_input_exit|other

hook_event_name:x("TeammateIdle"), teammate_name:i(), team_name:i()
```

`SubagentStop` carries `stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message` **[docs]**.
`PreCompact` / `PostCompact` carry `trigger` (`manual|auto`) and `custom_instructions` / `compact_summary` **[docs]**.

### 1.4 ★ "The agent is waiting for the user"

**Yes — `Notification` carries `notification_type`, and it is a real, documented field.** The full enum is hard-coded in the binary **[bin]**:

```js
kar=["permission_prompt","idle_prompt","auth_success","elicitation_dialog","agent_needs_input",
     "agent_completed","elicitation_url_dialog","worker_permission_prompt","push_notification",
     "computer_use_enter","computer_use_exit","quota_auto_resume_fired","quota_auto_resume_stale",
     "quota_auto_resume_disabled"]
```

(The public docs list 12 values and also mention `elicitation_complete` / `elicitation_response`; the binary adds `push_notification`, `computer_use_enter`, `computer_use_exit`, `worker_permission_prompt`. Treat the union as the real surface.) **[bin] [docs]**

Documented payload, verbatim **[docs]**:

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../00893aaf-19fa-41d2-8238-13269b9b3ca0.jsonl",
  "cwd": "/Users/...",
  "hook_event_name": "Notification",
  "message": "Claude needs your permission",
  "title": "Permission needed",
  "notification_type": "permission_prompt"
}
```

**The critical caveat — do not build the "waiting" state on `Notification`.** Docs, verbatim:

> Expect `permission_prompt` once you haven't typed for about six seconds. The timer starts when the permission prompt appears, and each keystroke defers it. **To run a hook immediately when Claude asks for permission to use a tool, use PermissionRequest instead.**
> Expect `idle_prompt` about 60 seconds after Claude finishes responding, and only if you haven't typed since.

So for Notch:

| Desired island state | Correct event |
|---|---|
| "Claude needs your approval" — **instant** | `PermissionRequest` (fires synchronously, carries `tool_name` + `tool_input`, so you can render *what* is being asked) |
| "Waiting for you" — soft/idle | `Notification` + `notification_type == "permission_prompt"` or `"idle_prompt"` |
| Approval was refused | `PermissionDenied` (`reason`, e.g. `"[Irreversible Local Destruction]"`) |

`Notification` has **no decision control** — its `systemMessage` / `continue` are discarded (only `terminalSequence` survives), so it can never block Claude **[docs]**. `PermissionRequest` *can* decide (`hookSpecificOutput.decision.behavior`) — Notch must therefore emit **no** JSON from a `PermissionRequest` hook and exit 0, or it will start auto-approving tools.

Historical note: GitHub issue [anthropics/claude-code#11964](https://github.com/anthropics/claude-code/issues/11964) reported `notification_type` *missing* (Nov 2025, closed "not planned"); it is present in current builds. Keep a fallback that matches `message` against `"Claude needs your permission"` / `"…to use <Tool>"`. Issue [#32952](https://github.com/anthropics/claude-code/issues/32952) notes the `permission_prompt` payload doesn't say *what* is requested — another reason to prefer `PermissionRequest`.

### 1.5 `~/.claude/settings.json` `hooks` structure

Three levels: **event → matcher group → handlers**. What Seam actually wrote on this machine **[disk]** (`~/.claude/settings.json`):

```json
"hooks" : {
  "PostToolUse" : [ { "hooks" : [ { "command" : "/Users/…/.seam/hooks/seam-claude-code.sh",
                                    "type" : "command" } ],
                      "matcher" : "" } ],
  "PreToolUse"  : [ { "hooks" : [ { "command" : "/Users/…/.seam/hooks/seam-claude-code.sh",
                                    "type" : "command" } ],
                      "matcher" : "" } ],
  "Stop"        : [ { "hooks" : [ { "command" : "/Users/…/.seam/hooks/seam-claude-code.sh",
                                    "type" : "command" } ] } ],
  "UserPromptSubmit" : [ { … } ]
}
```

Note Seam writes `"matcher": ""` (match-all) on the tool events and omits `matcher` entirely on `Stop`.

Matcher semantics **[docs]**:

| Matcher value | Evaluated as |
|---|---|
| `"*"`, `""`, omitted | match all |
| only `[A-Za-z0-9_\- ,\|]` | exact string, or `\|`/`,`-separated exact list |
| anything else | **unanchored JavaScript regex** (`Edit.*` also matches `NotebookEdit`; use `^Edit$`) |

Handler fields **[docs]**: `type` ∈ `command | http | mcp_tool | prompt | agent`; plus `if` (permission-rule filter, tool events only), `timeout` (default **600 s** for command/http/mcp_tool), `statusMessage`, `args`, `async`, `asyncRewake`, `shell`.
Gotcha: *"A command hook runs as exec form when `args` is set, and shell form when `args` is omitted."*

Settings locations, merged rather than replaced (*"Hook entries merge across settings levels rather than replacing each other."*) **[docs]**:
`~/.claude/settings.json` (user) · `.claude/settings.json` (project) · `.claude/settings.local.json` · managed `/Library/Application Support/ClaudeCode/managed-settings.json` · plugin `hooks/hooks.json` · skill/subagent frontmatter.
Enterprise `allowManagedHooksOnly` can disable all user hooks — Notch must handle "install succeeded but nothing ever fires."

Exit-code contract **[docs]**: exit 0 → stdout to debug log (except `UserPromptSubmit`/`UserPromptExpansion`/`SessionStart`/`PostModelSwitch`, where stdout becomes context); exit 2 → blocking error; **JSON on stdout is parsed on every exit code**, and invalid JSON surfaces a visible `<hook name> hook error`. This is exactly why Seam's shims end `>/dev/null 2>&1 || true; exit 0`.

Env: `${CLAUDE_PROJECT_DIR}` (project root, stable across worktrees), `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`.

### 1.6 Seam's Claude Code shim — exact stage mapping

`/Users/vladislavzidko/.seam/hooks/seam-claude-code.sh` **[disk]**, verbatim core:

```js
var event = input.hook_event_name || "";
var tool  = input.tool_name || "";
var sessionId = input.session_id || "";
var sourceApp = …environment.objectForKey($("TERM_PROGRAM")) || "";

if (event === "UserPromptSubmit") {
    // Marks the start of a turn. Without this hook the working
    // state cannot show during pure-thinking time before the first tool call.
    stage = "thinking";
} else if (event === "PreToolUse") {
    if (["Edit","Write","MultiEdit","Bash"].indexOf(tool) >= 0)          { stage="writing";   message=tool; }
    else if (["Read","Grep","Glob","Agent","Explore"].indexOf(tool) >= 0){ stage="analyzing"; message=tool; }
    else                                                                 { stage="thinking";  message=tool; }
} else if (event === "PostToolUse") {
    // PostToolUse keeps the activity alive between tool calls.
    stage = "thinking"; message = tool;
} else if (event === "Stop") {
    stage = "completed";
}
…
dnc.postNotificationNameObjectUserInfoDeliverImmediately(
    $("app.seam.claudecode.event"), $("seam"), info, true);
```

Header comment, verbatim: *"MUST NEVER block Claude Code. All errors are swallowed and the script always exits 0 so a missing/broken Seam install can never break tool calls or surface 'hook error' notices in the Claude Code transcript."*

`sourceApp` is `$TERM_PROGRAM` — `Apple_Terminal`, `iTerm.app`, `WarpTerminal`, `ghostty`, `alacritty`, `vscode`, `cursor` are all listed in the Seam binary **[bin]**.

---

## 2. Codex CLI hooks

### 2.1 TOML format — three levels, not two

`[[hooks.X]]` holds only `matcher`; handlers live in a nested `[[hooks.X.hooks]]`; `command` is a **String**, not an array.

Seam's block, verbatim from this machine's `~/.codex/config.toml` lines 1923–1945 **[disk]**:

```toml
# === managed by Seam.app - code event hooks (begin) ===
[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/Users/vladislavzidko/.seam/hooks/seam-codex-hook.sh"

[[hooks.PreToolUse]]
matcher = "*"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "/Users/vladislavzidko/.seam/hooks/seam-codex-hook.sh"

[[hooks.PostToolUse]]
matcher = "*"
[[hooks.PostToolUse.hooks]]
type = "command"
command = "/Users/vladislavzidko/.seam/hooks/seam-codex-hook.sh"

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "/Users/vladislavzidko/.seam/hooks/seam-codex-hook.sh"
# === managed by Seam.app - code event hooks (end) ===
```

Seam also sets `[features] hooks = true` (line 1765/1769 of the same file) **[disk] [bin]**.

Handler schema, `codex-rs/config/src/hook_config.rs` **[oss]**:

```rust
#[serde(tag = "type")]
pub enum HookHandlerConfig {
    #[serde(rename = "command")]
    Command {
        command: String,
        #[serde(default, rename = "commandWindows", alias = "command_windows")]
        command_windows: Option<String>,
        #[serde(default, rename = "timeout")] timeout_sec: Option<u64>,
        #[serde(default)] r#async: bool,
        #[serde(default, rename = "statusMessage")] status_message: Option<String>,
        #[serde(default, rename = "additionalContextLimit")] additional_context_limit: Option<usize>,
    },
    #[serde(rename = "mcp_tool")] McpTool { … },
    #[serde(rename = "prompt")] Prompt {},
    #[serde(rename = "agent")] Agent {},
}
```

`timeout` is **seconds**, default 600 (1 s for `SessionEnd`/`Interrupt`, max 3 s there). `prompt` and `agent` handlers are parsed but skipped.

### 2.2 All 12 events

`HookEventsToml` **[oss]**: `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt`.

`matcher` is honoured only on `PermissionRequest`/`PreToolUse`/`PostToolUse` (tool name), `PreCompact`/`PostCompact` (`manual|auto`), `SessionStart` (`startup|resume|clear|compact`), `SessionEnd`, `SubagentStart`/`SubagentStop`. *"Any configured `matcher` is ignored"* for `UserPromptSubmit`, `Stop`, `Interrupt` — which is why Seam's `matcher = "*"` on `Stop` would have been pointless and it omits it.

### 2.3 stdin fields

Common **[docs]**: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model` (Codex extension), and on most events `permission_mode` (`default|acceptEdits|plan|dontAsk|bypassPermissions`).

**There is no `thread_id` field** — turn-scoped events carry `turn_id`; `session_id` *is* the thread. Seam's shim reads `input.session_id || input["thread-id"]`, the second being the *legacy notify* spelling **[disk]**.

Per event: `UserPromptSubmit` +`turn_id`,`prompt` · `PreToolUse` +`turn_id`,`tool_name`,`tool_use_id`,`tool_input` · `PostToolUse` also `tool_response` · `Stop` +`turn_id`,`stop_hook_active`,`last_assistant_message` · `SubagentStop` also `agent_id`,`agent_type`,`agent_transcript_path`. Generated JSON schemas live at `codex-rs/hooks/schema/generated/*.json`; `stop.command.input.schema.json` `required` is:

```json
["cwd","hook_event_name","last_assistant_message","model","permission_mode",
 "session_id","stop_hook_active","transcript_path","turn_id"]
```

### 2.4 `~/.codex/hooks.json` and how sources coexist

`hooks.json` is fully supported and **merged**, never overridden. Codex discovers `~/.codex/hooks.json`, `~/.codex/config.toml`, `<repo>/.codex/hooks.json`, `<repo>/.codex/config.toml` **[docs]**:

> If more than one hook source exists, Codex loads all matching hooks. Higher-precedence config layers don't replace lower-precedence hooks. If a single layer contains both `hooks.json` and inline `[hooks]`, Codex merges them and warns at startup.
> Matching hooks from multiple files all run. Multiple matching command hooks for the same event are launched concurrently, so one hook can't prevent another matching hook from starting.

This machine proves it: **OMX (oh-my-codex) owns `~/.codex/hooks.json` while Seam owns the `[[hooks.*]]` block in `config.toml`, and both run.** **[disk]**

```json
// ~/.codex/hooks.json  — events present: SessionStart, PreToolUse, PostToolUse,
//                        UserPromptSubmit, PreCompact, PostCompact, Stop
{
  "state": {
    "/Users/…/.codex/hooks.json:pre_tool_use:0:0": { "trusted_hash": "sha256:9ddbb954…" },
    …
  },
  "hooks": {
    "SessionStart": [ { "matcher": "startup|resume|clear",
                        "hooks": [ { "type": "command", "command": "\"/usr/local/bin/node\" \"…/codex-native-hook.js\"" } ] } ],
    "PreToolUse":   [ { "matcher": "Bash", "hooks": [ … ] } ],
    "Stop":         [ { "hooks": [ { "type": "command", "command": "…", "timeout": 30 } ] } ]
  }
}
```

**Trust gate — the biggest install hazard.** Codex refuses to run an untrusted hook: *"Before a non-managed hook can run, Codex requires you to review and trust the exact hook definition. Codex records trust against the hook's current hash, so new or changed hooks are marked for review and skipped until trusted."* The records are the `state` map above, mirrored into `config.toml` as `[hooks.state."<file>:<snake_case_event>:0:0"]` with `enabled` / `trusted_hash` **[disk]**. Users clear it with `/hooks` in the TUI. Notch must tell the user to run `/hooks` after install, or its hooks will silently never fire.

### 2.5 Legacy `notify`

```toml
notify = ["python3", "/path/to/notify.py"]
```

One event only (`agent-turn-complete`), payload appended as **argv[1]**, spawned with `stdin` null, fire-and-forget. Wire shape pinned by the Rust test `expected_notification_json` **[oss]**:

```json
{ "type": "agent-turn-complete",
  "thread-id": "b5f6c1c2-1111-2222-3333-444455556666",
  "turn-id": "12345",
  "cwd": "/Users/example/project",
  "client": "codex-tui",
  "input-messages": ["Rename `foo` to `bar` and update the callsites."],
  "last-assistant-message": "Rename complete and verified `cargo build` succeeds." }
```

`notify` and lifecycle hooks are **independent pipelines** (`after_agent` vs `engine` in `codex-rs/hooks/src/registry.rs`): `notify` fires *in addition to* `Stop`, is **not** gated by `[features].hooks`, and is **not** subject to hook trust. It is deprecated in-source. This machine's `notify` is claimed by Codex Computer Use, which chain-calls OMX's `notify-hook.js` via `--previous-notify` **[disk]** — i.e. `notify` is a single-slot resource and third parties fight over it. **Do not use `notify` for Notch.**

### 2.6 Seam's Codex shim

`/Users/vladislavzidko/.seam/hooks/seam-codex-hook.sh` handles both transports **[disk]**:

```bash
if [ -t 0 ]; then
    SEAM_CODEX_PAYLOAD="$1"            # legacy notify
else
    SEAM_CODEX_PAYLOAD="$(/bin/cat)"   # new [hooks] stdin
    [ -z "$SEAM_CODEX_PAYLOAD" ] && [ -n "$1" ] && SEAM_CODEX_PAYLOAD="$1"
fi
```
```js
var event = input.hook_event_name || input.type || "";
var sessionId = input.session_id || input["thread-id"] || "";
if (event === "UserPromptSubmit")      stage = "thinking";
else if (event === "PreToolUse") {
    if (["apply_patch","shell"].indexOf(tool) >= 0)      { stage="writing";   message=tool; }
    else if (["read_file","view_image"].indexOf(tool)>=0){ stage="analyzing"; message=tool; }
    else                                                 { stage="thinking";  message=tool; }
}
else if (event === "PostToolUse")      { stage="thinking"; message=tool; }
else if (event === "Stop" || event === "agent-turn-complete") {
    stage = "completed";
    var lastMsg = input.last_assistant_message || input["last-assistant-message"] || "";
    if (lastMsg.length > 80) lastMsg = lastMsg.substring(0, 80);
    message = lastMsg;
}
```

Comment, verbatim: *"Codex tool names vary across releases. Map a few well-known ones, fall through to 'thinking' otherwise."*

---

## 3. Cursor hooks

### 3.1 `~/.cursor/hooks.json` — what Seam wrote

Verbatim from this machine **[disk]**:

```json
{
  "hooks" : {
    "afterFileEdit"      : [ { "command" : "/Users/…/.seam/hooks/seam-cursor-hook.sh", "timeout" : 5 } ],
    "beforeSubmitPrompt" : [ { "command" : "…", "timeout" : 5 } ],
    "postToolUse"        : [ { "command" : "…", "timeout" : 5 } ],
    "preToolUse"         : [ { "command" : "…", "timeout" : 5 } ],
    "stop"               : [ { "command" : "…", "timeout" : 5 } ]
  },
  "version" : 1
}
```

Schema confirmed by <https://cursor.com/docs/agent/hooks> **[docs]**: `{"version": 1, "hooks": { "<event>": [ {"command": "…"} ] }}`. Entries are **objects**, not bare strings.

Per-script options **[docs]**: `command` (required), `type` (`command`|`prompt`, default `command`), `timeout` (seconds), `loop_limit` (default 5, for stop/subagentStop), `failClosed` (default `false`), `matcher`.

### 3.2 Event list **[docs]**

*Agent*: `sessionStart`, `sessionEnd`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `subagentStart`, `subagentStop`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeSubmitPrompt`, `preCompact`, `stop`, `afterAgentResponse`, `afterAgentThought`.
*Tab*: `beforeTabFileRead`, `afterTabFileEdit`. *App*: `workspaceOpen`.

### 3.3 stdin fields

Common to every hook **[docs]**:

```json
{ "conversation_id": "string", "generation_id": "string", "model": "string", "model_id": "string",
  "model_params": [{ "id": "string", "value": "string" }], "hook_event_name": "string",
  "cursor_version": "string", "workspace_roots": ["<path>"],
  "user_email": "string | null", "transcript_path": "string | null" }
```

Per event:

* `preToolUse`: `tool_name`, `tool_input`, `tool_use_id`, `cwd`, `agent_message`
* `postToolUse`: + `tool_output`, `duration`
* `afterFileEdit`: `file_path`, `edits: [{old_string, new_string}]`
* `beforeSubmitPrompt`: `prompt`, `attachments` — the field is **`prompt`**, not `text`
* `stop`: `{ "status": "completed" | "aborted" | "error", "loop_count": 0 }`

Seam's shim uses `input.conversation_id` as the session id and maps `stop` as `input.status === "error" ? "failed" : "completed"`, with the verbatim comment *"status is completed, aborted or error. Only a real error is a failure, an aborted turn is the user stopping the agent."* **[disk]**

### 3.4 Blocking and merge

**Cursor blocks on the hook process** — Seam's script header says so explicitly: *"Cursor waits on this script before continuing its agent loop, so every error is swallowed and the script always exits 0."* **[disk]** Exit 0 → use JSON output; exit 2 → block; other codes → fail-open unless `failClosed: true` **[docs]**.

Config locations, priority Enterprise → Team → Project → User: `/Library/Application Support/Cursor/hooks.json`, cloud team config, `<repo>/.cursor/hooks.json`, `~/.cursor/hooks.json`. *"All matching hooks from every source run; when responses conflict, higher-priority sources take precedence during merge."* **[docs]**

Working-directory gotcha: project hooks run from the project root, user hooks from `~/.cursor/` — Seam sidesteps it by writing an absolute path. Env vars supplied: `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH`, `CURSOR_CODE_REMOTE`, plus a `CLAUDE_PROJECT_DIR` alias.

---

## 4. Usage / rate-limit statistics

### 4.1 Claude

**Credentials.** macOS Keychain generic password, service **`Claude Code-credentials`**. Confirmed on this machine **[disk]**:

```
class: "genp"
0x00000007 <blob>="Claude Code-credentials"
"acct"<blob>="vladislavzidko"          # = the macOS short user name
"svce"<blob>="Claude Code-credentials"
```

The binary builds the service name as `<suffix>` concat: `var g5="-credentials"` **[bin]**. Payload JSON **[oss]**:

```json
{ "claudeAiOauth": {
    "accessToken":  "sk-ant-oat01-…",
    "refreshToken": "sk-ant-ort01-…",
    "expiresAt":    1748276587173,        // epoch MILLIseconds
    "scopes":       ["user:inference", "user:profile"],
    "subscriptionType": "…",
    "rateLimitTier":    "…"
} }
```

Fallback file: `~/.claude/.credentials.json` (deleted on macOS after Keychain migration).
⚠️ Two traps documented by CodexBar/claude-code issues: the item can contain **only `mcpOAuth`** and no `claudeAiOauth` on some 2.1.x installs ([CodexBar#1844]); and setting `CLAUDE_CODE_OAUTH_TOKEN` makes the CLI **delete** the Keychain item on exit ([claude-code#37512]).

> *Note:* I attempted a live read + API call to verify the response body first-hand; the sandbox classifier blocked reading the secret, correctly. Everything below is from the CLI binary and open source, not from this machine's token.

**Usage endpoint.** Confirmed directly in the Claude Code binary **[bin]**:

```js
async function BO(e,{atWall:n=!1}={}){ …
  let r = n ? "/api/oauth/usage?at_wall=1&skip_spend=1" : "/api/oauth/usage", o=0,
      d = await I_(async()=>{ o++;
        let f = await St.get(r,{ timeout:5000,
                                 headers:{"Content-Type":"application/json"},
                                 refreshOAuth:!0, credentials:e });
        if(!f.ok) throw Error(`Auth error: …`); return f });
  return d.data })
```

Base `https://api.anthropic.com`, beta header `oauth-2025-04-20` (string present in both the Claude binary **[bin]** and Seam's binary **[bin]**), **5 s timeout**, 401 → refresh → retry once.

CodexBar's request builder **[oss]**:

```swift
private static let baseURL = "https://api.anthropic.com"
private static let usagePath = "/api/oauth/usage"
private static let profilePath = "/api/oauth/profile"
private static let betaHeader = "oauth-2025-04-20"
…
request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Accept")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
request.setValue(Self.claudeCodeUserAgent(…), forHTTPHeaderField: "User-Agent")
```

⚠️ **`User-Agent: claude-code/<version>` is effectively mandatory** — without it you land in a punishing rate-limit bucket and get sticky 429s with no `Retry-After` ([claude-code#31637]). Seam hard-codes exactly this: the string `claude-code/unknown` sits next to the endpoint in its binary **[bin]**.

**Response shape.** Seam parses `five_hour`, `seven_day`, `utilization`, `resets_at` **[bin]**. The full surface **[oss]**:

```json
{
  "five_hour":            { "utilization": 42.0, "resets_at": "<ISO-8601>" },
  "seven_day":            { "utilization": …,    "resets_at": "…" },
  "seven_day_opus":       { … },
  "seven_day_sonnet":     { … },
  "seven_day_oauth_apps": { … },
  "extra_usage":          { "is_enabled": true, "monthly_limit": …, "used_credits": …, "utilization": …, "currency": "…" },
  "limits": [ { "kind": "weekly_scoped", "group": "weekly", "percent": …, "resets_at": "…",
                "scope": { "model": { "id": "…", "display_name": "…" } }, "is_active": true } ]
}
```

Both `utilization` and `resets_at` are **optional**, and `resets_at` is a **string**, not an epoch int. A newer `limits[]` array supersedes the flat `seven_day_*` keys for model-scoped weekly windows — the Claude binary knows the same key set **[bin]**:

```js
eQr=["five_hour","seven_day","seven_day_oauth_apps","seven_day_opus","seven_day_sonnet",
     "cinder_cove","extra_usage","limits"]
```

Account/org identity is on a **separate** endpoint, `GET /api/oauth/profile` → `{"account":{"email_address":…},"organization":{"uuid":…}}` **[oss]**.

**Token refresh.** `client_id = 9d1c250a-e61b-44d9-88ed-5944d1962f5e` — present verbatim in the Claude Code binary **[bin]** and in CodexBar **[oss]**. ⚠️ The host has moved: CodexBar `main` posts to **`https://platform.claude.com/v1/oauth/token`**; `console.anthropic.com/v1/oauth/token` is the historical form. The binary itself builds `TOKEN_URL: \`${BASE_API_URL}/v1/oauth/token\`` from a configurable base **[bin]** — so treat the host as a constant to keep updatable, and the path as stable.

```
POST …/v1/oauth/token
Content-Type: application/x-www-form-urlencoded
grant_type=refresh_token&refresh_token=…&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e
→ { "access_token": "…", "refresh_token": "…"|absent, "expires_in": 3600, "token_type": "Bearer" }
```

`refresh_token` may **not** rotate — keep the old one if absent. Distinguish HTTP+`invalid_grant` (terminal → force re-auth) from transient failures (backoff).

**★ Zero-credential alternative: the status line.** Claude Code pipes a rich JSON blob into `settings.json → statusLine.command`, and it already contains the rate limits. Verbatim from the binary's own doc comment **[bin]**:

```
"rate_limits": {   // Optional: Claude.ai subscription usage limits … Only present for
                   // subscribers … after first API response, while at least one window is present.
  "five_hour": {   // Optional: 5-hour session limit (present only while … resets_at has not passed)
    "used_percentage": number,   // Percentage of limit used (0-100)
    "resets_at": number          // Unix epoch seconds when this window resets
  },
  "seven_day": { "used_percentage": number, "resets_at": number },
  "spend_limit": { "used_percentage": number, "resets_at": number }
},
"context_window": { "total_input_tokens": …, "context_window_size": …,
                    "used_percentage": number|null, "remaining_percentage": number|null },
"model": { "id": …, "display_name": … }, "workspace": { "current_dir": …, "project_dir": … },
"version": "…", "effort": { "level": "low"|"medium"|"high"|"xhigh"|"max" }
```

Internally the CLI models this as **[bin]**:

```js
c({ status: ee(["allowed","allowed_warning","rejected"]), resetsAt:A().int().optional(),
    rateLimitType: ee(["five_hour","seven_day","seven_day_opus","seven_day_sonnet",
                       "seven_day_overage_included","overage"]).optional(),
    utilization: A().optional(),
    unifiedWindows: c({ five_hour: c({utilization:A(), resetsAt:A().int()}).optional(),
                        seven_day: c({…}).optional(),
                        seven_day_overage_included: c({…}).optional() }).optional() })
```

**This is the single biggest improvement Notch can make over Seam**: a status-line command gives live five_hour/seven_day percentages, the current model, cwd and context-window usage — with **no Keychain access, no OAuth token, no HTTP call, no rate-limit bucket**. Seam does not use it.

**7-day sparkline from local transcripts.** Seam scans `~/.claude/projects/**/*.jsonl` and caches into `~/Library/Application Support/Seam/claude-usage-cache-v2.json` (v1 name `claude-usage-cache.json` also in the binary). Verified on disk — 76 entries, shape **[disk]**:

```json
{ "/Users/…/.claude/projects/-Users-…-trivia/39d207ef-….jsonl":
    { "modDate": 810290844.9738531,                    // CFAbsoluteTime (seconds since 2001-01-01)
      "buckets": { "2026-09-05-11": 114118 } } }        // "YYYY-MM-DD-HH" → total tokens
```

Internal model names **[bin]**: `ClaudeUsageParser { projectsPath, fileCache, hourlyTokensToday, modDate, buckets }`; the Codex twin is `CodexDailyTotalsParser { sessionsPath, fileCache, hourlyTokensToday, modDate, tokens }` — so Seam computes Codex daily totals from rollouts too, without persisting them.

The JSONL line shape, verified on this machine **[disk]** (a real assistant line):

```
.type = "assistant"
.timestamp = "2026-09-11T17:02:43.318Z"
.sessionId, .requestId = "req_011C…", .version = "2.1.260", .cwd, .gitBranch
.message.model = "claude-fable-5-1", .message.id = "msg_…"
.message.usage.input_tokens = 2
.message.usage.cache_creation_input_tokens = 28078
.message.usage.cache_read_input_tokens = 41039
.message.usage.output_tokens = 234
.message.usage.output_tokens_details.thinking_tokens = 129
.message.usage.cache_creation.ephemeral_1h_input_tokens = 28078
.message.usage.cache_creation.ephemeral_5m_input_tokens = 0
.message.usage.service_tier = "standard"
```

ccusage (now `ccusage/ccusage`, rewritten in Rust) is the reference implementation **[oss]**:

```rust
fn usage_token_total(data: &UsageEntry) -> u64 {
    let usage = data.message.usage;
    usage.input_tokens + usage.output_tokens
        + usage.cache_creation_token_count() + usage.cache_read_input_tokens
}
// cache_creation_token_count(): prefer cache_creation.ephemeral_5m + ephemeral_1h,
// else fall back to the flat cache_creation_input_tokens
fn usage_dedupe_hash(message_id: &str, request_id: Option<&str>, session_id: &str) -> u64 { … }
```

Three practical rules ccusage encodes: dedupe on **(message.id, requestId, sessionId)**; prefer the nested `cache_creation.ephemeral_*` over the flat field; don't filter on `type` — prefilter on the byte substring `"usage":{` and let the decoder reject the rest. Discovery honours `CLAUDE_CONFIG_DIR`, else `$XDG_CONFIG_HOME/claude`, else `~/.claude`, requiring a `projects/` subdir.

### 4.2 Codex

**Two probes in Seam, and the local one is currently broken.**

*`CodexLocalQuotaProbe.swift`* — SQLite over the Codex log DB **[bin]**:

```
PRAGMA table_info(logs)
… FROM logs WHERE <col> LIKE '%"type":"codex.rate_limits"%' ORDER BY id DESC LIMIT 20
```
Homes searched: `~/.codex/sessions`, `codex-accounts/*/home`, `codex-runtime-home/home`. Errors: `No rate-limit records in any Codex home`, `No Codex home found`.

On this machine the column it dynamically discovers is **`feedback_log_body`** (also a literal string in Seam's binary) **[disk] [bin]**:

```
$ sqlite3 -readonly ~/.codex/logs_2.sqlite "PRAGMA table_info(logs);"
0|id|INTEGER  1|ts|INTEGER  2|ts_nanos|INTEGER  3|level|TEXT  4|target|TEXT
5|feedback_log_body|TEXT  6|module_path|TEXT  7|file|TEXT  8|line|INTEGER …
```

…but **zero rows** match `"type":"codex.rate_limits"` in codex-cli 0.146.0 **[disk]**. That legacy log target is gone. Notch should not implement this probe.

*`CodexRPCQuotaProbe.swift`* — the one that works. Seam spawns the `codex` binary (`/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex`) as an app-server and writes three lines **[bin]**:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Seam","version":"1.0.0"}}}
{"jsonrpc":"2.0","method":"initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}
```

Errors: `Codex CLI not found`, `could not launch codex:`, `could not write to codex app-server`, `codex app-server closed before answering`, `rate-limit response had no rateLimits payload`, `rate-limit payload could not be classified`, `No Codex home has valid credentials`.

**Seam's own calls are visible in Codex's log DB** — direct proof the mechanism works **[disk]**:

```
2026-09-11 20:04:24 | codex_app_server::request_processors::account_processor::rate_limit_resets |
app_server.request{ otel.name="account/rateLimits/read" rpc.method="account/rateLimits/read"
  rpc.transport="stdio" rpc.request_id=2 app_server.api_version="v2"
  app_server.client_name="Seam" app_server.client_version="1.0.0" }:
rate limit reset credit detail request timed out; falling back to the usage response
```

**I reproduced the exchange live** against codex-cli 0.146.0 **[live]**:

```json
{"id":1,"result":{"userAgent":"NotchResearch/0.146.0 (Mac OS 26.5.2; arm64) unknown (NotchResearch; 1.0.0)",
                  "codexHome":"/Users/…/.codex","platformFamily":"unix","platformOs":"macos"}}
{"method":"remoteControl/status/changed","params":{"status":"disabled", …},"emittedAtMs":…}
{"id":2,"result":{
  "rateLimits":{ "limitId":"codex","limitName":null,
    "primary":{"usedPercent":77,"windowDurationMins":43200,"resetsAt":1790147743},
    "secondary":null,
    "credits":{"hasCredits":false,"unlimited":false,"balance":null},
    "individualLimit":null,"spendControlReached":false,
    "planType":"free","rateLimitReachedType":null },
  "rateLimitsByLimitId":{ "codex":{ …same… } },
  "rateLimitResetCredits":{ "availableCount":1, "credits":[
    {"id":"RateLimitResetCredit_…","resetType":"codexRateLimits","status":"available",
     "grantedAt":…, "expiresAt":…, "title":"Full reset (Monthly)",
     "description":"Thanks for using Codex! You've been granted one free rate limit reset."}]}}}
```

Note an unsolicited `remoteControl/status/changed` notification arrives between the two responses — a reader must correlate by `id`, not by line order.

**Wire-format trap: the same data has two spellings.** The app-server is camelCase; the rollout JSONL is snake_case.

| | app-server (`v2/account.rs`) | rollout JSONL (`protocol.rs`) |
|---|---|---|
| percent | `usedPercent` (**i32**, rounded) | `used_percent` (**f64**) |
| window | `windowDurationMins` | `window_minutes` |
| reset | `resetsAt` | `resets_at` |

Seam's binary contains **both** alias sets verbatim, adjacent **[bin]**:

```
used_percent / usedPercent / window_minutes / windowDurationMins / resets_at / reset_at / resetsAt
```

Rust definitions **[oss]**:

```rust
pub struct RateLimitSnapshot {
    pub limit_id: Option<String>, pub limit_name: Option<String>,
    pub normal_model_slug: Option<String>,
    pub primary: Option<RateLimitWindow>, pub secondary: Option<RateLimitWindow>,
    pub credits: Option<CreditsSnapshot>, pub individual_limit: Option<SpendControlLimitSnapshot>,
    pub spend_control_reached: Option<bool>, pub plan_type: Option<PlanType>,
    pub rate_limit_reached_type: Option<RateLimitReachedType>,
}
pub struct RateLimitWindow {
    pub used_percent: f64,                 // 0-100
    pub window_minutes: Option<i64>,       // rolling window, minutes
    pub resets_at: Option<i64>,            // Unix epoch SECONDS
}
```

⚠️ `resets_in_seconds` is **legacy** — present up to `rust-v0.45.0`, replaced by `resets_at` from `rust-v0.50.0`.

**Rollout files.** `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<thread_id>.jsonl`. Verified line on this machine **[disk]**:

```
.timestamp = "2026-06-25T10:47:46.734Z"   .ordinal = 16   .type = "event_msg"
.payload.type = "token_count"
.payload.info.total_token_usage.{input_tokens,cached_input_tokens,cache_write_input_tokens,
                                 output_tokens,reasoning_output_tokens,total_tokens}
.payload.info.last_token_usage.{…same…}
.payload.info.model_context_window = 237500
.payload.rate_limits.limit_id = "codex"
.payload.rate_limits.primary.used_percent = 4.0
.payload.rate_limits.primary.window_minutes = 300
.payload.rate_limits.primary.resets_at = 1782397669
.payload.rate_limits.secondary.{used_percent:1.0, window_minutes:10080, resets_at:1782984469}
.payload.rate_limits.plan_type = "prolite"
```

⚠️ Rollouts older than **7 days are zstd-compressed in place** (`.jsonl.zst`) — a scanner must glob both **[oss]**. 4 389 rollout files exist on this machine, so incremental mtime caching (Seam's approach) is mandatory.

**Auth.** `~/.codex/auth.json`, keys `OPENAI_API_KEY`, `tokens.{id_token, access_token, refresh_token, account_id}`, `last_refresh`, `personal_access_token`, `auth_mode`, `bedrock_*` **[oss]**. But `cli_auth_credentials_store` may be `keyring` (service `CODEX_AUTH`) or `ephemeral` — **the file may not exist** even for a signed-in user. Prefer the app-server RPC, which resolves auth itself.

There is **no `codex usage` subcommand**; `/status` and `/usage` are TUI slash commands backed by the same `account/rateLimits/read`. Related methods: `account/rateLimitResetCredit/consume`, `account/usage/read` (lifetime/peak/streak + `dailyUsageBuckets:[{startDate,tokens}]`), and the push notification `account/rateLimits/updated`.

### 4.3 Cursor

**Token.** Seam's exact SQL, a literal in its binary and identical to every OSS reader **[bin] [oss]**:

```sql
SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';
```
from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, executed via `/usr/bin/sqlite3` (Seam links `libsqlite3` but shells out here). Verified present on this machine **[disk]** — keys `cursorAuth/accessToken` (424 B), `refreshToken`, `cachedEmail`, `cachedSignUpType`, `stripeMembershipType`, `stripeSubscriptionStatus`, `cachedScopedProfile`, `onboardingDate`, `openAIKey`.

**Cookie construction** — the JWT's `sub` is `auth0|user_xxx`; take the part after `|`, join with a URL-encoded `::` **[oss]**:

```typescript
const sub = decoded.payload.sub.toString();
const userId = sub.split('|')[1];
const sessionToken = `${userId}%3A%3A${token}`;
// Cookie: WorkosCursorSessionToken=<sessionToken>
```
Seam's binary holds the matching literals `https://cursor.com` and `WorkosCursorSessionToken=` **[bin]**.
Practical detail from CodexBar: the BLOB may be **BOM-less UTF-16LE** — try that before UTF-8; and reject a JWT with <60 s of life **[oss]**.

**Endpoints Seam calls** (in its own priority order — `UsageSources.swift` ids are `claude`, `cursor-usage-summary`, `cursor-usage-legacy`) **[bin]**:

1. `GET /api/usage-summary` → parsed for `ondemandlimitcents`, `totalpercentused`. Errors `usage summary was not an object`, `unrecognized usage summary shape`.
2. `GET /api/usage?user=<id>` (legacy) → error `no request quota in legacy usage`. Returns **[oss]**:
   ```typescript
   { 'gpt-4': { numRequests, numRequestsTotal, numTokens, maxRequestUsage, maxTokenUsage },
     'gpt-3.5-turbo': {…}, 'gpt-4-32k': {…}, startOfMonth: string }
   ```
3. `POST /api/dashboard/get-filtered-usage-events` → `CursorUsageEventsParser.swift`. Body `{teamId?, userId?, startDate?, endDate?, page?, pageSize?}`; response **[oss]**:
   ```go
   type EventsResponse struct {
     TotalUsageEventsCount int          `json:"totalUsageEventsCount"`
     UsageEventsDisplay    []UsageEvent `json:"usageEventsDisplay"` }
   type UsageEvent struct {
     Timestamp, Model, Kind string; RequestsCosts float64; UsageBasedCosts string
     IsTokenBasedCall bool; TokenUsage TokenUsage; ChargedCents float64
     IsChargeable, IsHeadless bool; CursorTokenFee float64 … }
   ```
   ⚠️ POSTs need `Origin: https://cursor.com`; some endpoints reject requests without browser-ish headers.

Seam's key-alias table for these responses is in the binary **[bin]** — useful because Cursor's field naming is unstable:

```
ondemandcents meteredcents extracents budgetcents spendlimitcents
startofmonth periodstart cyclestart endofmonth periodend cycleend resetsat renewsat
percentused usedpercent usedcents totalcents totalcostcents includedcents limitcents allowancecents
timestamp createdAt created_at cents costcents totalcents tokens totaltokens
```
(lower-cased, so Seam is clearly doing case-insensitive key matching.)

Sibling endpoints worth knowing **[oss]**: `POST /api/dashboard/get-hard-limit` → `{hardLimit?, hardLimitPerUser?, noUsageBasedAllowed?}`; `POST /api/dashboard/get-monthly-invoice` `{month, year, includeUsageEvents}`; `GET /api/auth/stripe` → `{membershipType, isTeamMember, subscriptionStatus, …}`; `GET /api/auth/me` → user id/email. A Bearer alternative exists: `GET https://api2.cursor.sh/auth/usage` with `Authorization: Bearer <accessToken>` — no cookie, no userId derivation.

⚠️ All of the above are **reverse-engineered dashboard endpoints**, not the documented `api.cursor.com` Admin/Analytics APIs (which are Enterprise-team-only). They can break without notice. Seam's errors — `Cursor not installed`, `No Cursor session, sign in to the Cursor app`, `Cursor rejected the stored session`, `Cursor API returned …` — are the right granularity to copy.

### 4.4 Seam's usage data model

From the binary's field-name tables **[bin]**:

```
UsageWindow  { label, usedPercent, resetsAt, windowDuration }
UsageData    { source(claude|codex|cursor), sessionWindow, weeklyWindow, dailyTotals,
               lastUpdated, quotaObservedAt }
UsageRefreshCoordinator { sources, lastRefresh, refreshTask, retryTask, boundaryTask,
                          pollTask, isActive, onUpdate }
CodeUsageBars / AnimatedUsageBar { usage, color, iconAsset, sparklineHeight, window,
                                   barColorFn, _showPace, _animatedPercent }
```

`boundaryTask` alongside `pollTask` is the tell: Seam schedules **one refresh exactly at each window's `resetsAt`** in addition to periodic polling — so the bar snaps to 0% at the right second rather than up to a poll-interval late. Copy that. `quotaObservedAt` separate from `lastUpdated` lets the UI say "as of 4 min ago" when a fetch fails. *(inference)*

---

## 5. Seam's Code UI — states, settings, sounds, assets

### 5.1 Stage machine

The wire vocabulary (what the shell scripts emit) and the app's internal enum differ by one name **[disk] [bin]**:

| Wire `stage` | App `CodeEventStage` |
|---|---|
| `thinking` | `thinking` |
| `analyzing` | `analyzing` |
| `writing` | `creating` |
| — | `posting` |
| `completed` | `completed` |
| `failed` | `failed` |

Literal from the binary, in order **[bin]**: `analyzing, thinking, creating, posting, completed, failed`.

`CodeEvent` / `CodeAlertData` fields **[bin]**: `source, stage, message, sessionID, eventID, sourceApp, startedAt, lastUpdatedAt, eventCount, recentStages, timestamp`.

`CodeEventStateMachine` fields **[bin]**: `currentData, isDismissed, bufferedSessions, stageShownAt, pendingEvent, pendingTransition, hasActiveStageHold, sessions` with methods `present, updatePresented, dismiss, scheduleAutoDismiss, clearSession, scheduleDebounce, scheduleStageHold, cancelDebounce, cancelStageHold, cancelAutoDismiss`.

That is the whole hard part of the feature: **debounce** (coalesce the PostToolUse→PreToolUse storm), **stage hold** (a stage must stay visible a minimum time or `PostToolUse → thinking` erases the `writing` you just showed), **buffered sessions** (multiple concurrent agents), **auto-dismiss**. *(inference on the exact durations — no numeric strings are recoverable.)*

The monitor side **[bin]**: `distributedCenter, localCenter, sourceObservers, appActivationObserver, appDidBecomeActiveObserver, systemWakeObserver, settingsObserver, activeSources, autoDismissTask, debounceTask, stageHoldTask, usageCoordinator, _isSuppressedByCodeApp`. Note the **`systemWakeObserver`** — after sleep, distributed notifications posted while asleep are lost, so state is re-derived on wake.

### 5.2 Stage icons

Six SF Symbols sit contiguously between `CodeEventPayload` and `CodePane` in the binary **[bin]**:

```
terminal.fill   sparkles   magnifyingglass   brain   text.cursor   bell.fill
```
*(inference: `magnifyingglass` = analyzing, `brain` = thinking, `terminal.fill`/`text.cursor` = creating, `sparkles` = posting, `bell.fill` = the alert badge.)*

Agent icons in `Assets.car` **[disk]** — from `assets-car-info.json`:

```json
{ "Name": "ClaudeCodeIcon", "RenditionName": "ClaudeCodeIcon.png",
  "PixelWidth": 16, "PixelHeight": 16, "Scale": 1,
  "ColorModel": "Monochrome", "Colorspace": "gray gamma 22",
  "Template Mode": "template", "SizeOnDisk": 334 }
```
Same for `CodexIcon` / `CursorIcon`. All three are **16×16 monochrome template images** — they tint with the island's foreground colour. (The binary also carries a packed literal `CodexIcoClaudeCoCursorIcn` — an interleaved constant table, not three separate strings.)

### 5.3 Every user-visible string

Settings labels (`Seam/CodePane.swift`) **[bin]**:

| Key | Label / subtitle | Symbol |
|---|---|---|
| `codeEventsEnabled` | **Show code agent activity in Surface** / *Show code events* · footer *"See live activity when Claude Code or Codex are working."* | — |
| `codeEventsClaudeCodeEnabled` / `…CodexEnabled` / `…CursorEnabled` | per-agent master toggles | agent icon |
| `codeEventsShowOnCodeApp` | **Display when on code window** / *Show overlay when code app is focused* | — |
| `codeEventsShowAnalyzing` / `…ShowThinking` / `…ShowCreating` (+ `Codex`/`Cursor` variants) | per-stage visibility | — |
| `codeEvents{ClaudeCode,Codex,Cursor}ShowWhenIdle` | **Display usage when idle** | `gauge.with.needle` |
| `codeEventsPlayCompleteSound` | **Completion sound** / *Play a chime when a session completes* | `speaker.wave.2.fill` |
| `codeEventsShowPace` | **Show pace indicator on usage bars** | `gauge.with.needle.fill` |
| `codeEventsCaffeineDance` | *Agent icon sways and shifts colors while your Mac is held awake* | — |
| `codeEventsShowInfo`, `codeEventsCompactStyle` | no label recovered; `CodeCompactStyleSelector` is a card selector *(inference: 2–3 density presets)* | — |

Alerts pane **[bin]**: **Receive alerts when code completed** · *"Alerts may increase energy usage when running multiple code sessions."*
Menu (`Seam/AppMenuItems.swift`) **[bin]**: **Caffeinate Agent** (`cup.and.saucer.fill`) / **Stop Caffeinating Agent**, **Show Claude Usage** / **Show Codex Usage** / **Show Cursor Usage**.
Caffeine (`Seam/CaffeineView.swift`) **[bin]**: *Keep your Mac awake while agents work* · *Your Mac stays awake while agents work* · *Seam is keeping coding agents awake*.
Insights empty state **[bin]**: **No coding activity yet** · *Use Claude Code or Codex to see usage*.
Focus / Flow interop **[bin]**: *Code agent activity during Focus* (`focusAllowCodeEvents`), *Code agent activity during flow* (`flowAllowCodeEvents`).

⚠️ **"All sessions complete!"** is **not** a Code string — it lives in `Seam/FlowCompletedView.swift` (the Pomodoro timer), between `Seam/FlowExpandedView.swift` and `Start Flow session` **[bin]**. There are **no** localized stage captions: the island shows the agent icon + the animated stage glyph + `message` (the tool name), never the word "Analyzing".

### 5.4 Defaults

From `defaults read app.seam.Seam` on this machine, after normal use **[disk]**:

```
codeEventsEnabled = 1
codeEventsClaudeCodeEnabled = 1      codeEventsClaudeCodeShowWhenIdle = 1
codeEventsCodexEnabled = 1           codeEventsCodexShowWhenIdle = 1
codeEventsCursorEnabled = 1          codeEventsCursorShowWhenIdle = 1
codeEventsPlayCompleteSound = 1
```
Every other `codeEvents*` key is **absent**, i.e. still at its code default. `codeEventsShowPace`, `codeEventsCaffeineDance`, `codeEventsShowOnCodeApp`, `codeEventsCompactStyle`, `codeEventsShowInfo` and the per-stage toggles are therefore unwritten — the per-stage `Show{Analyzing,Thinking,Creating}` almost certainly default **on** *(inference: they are opt-out filters)*, and `codeEventsShowPace` / `codeEventsCaffeineDance` default **off** *(inference: they are described as extra flourishes)*.

### 5.5 Sound

`seam-code-complete` (`.caf`), played by `SoundPlayer.swift`, gated on `codeEventsPlayCompleteSound` **[bin]**. Siblings: `seam-intro, seam-lock, seam-unlock, seam-calendar, seam-low-battery, seam-flow-start, seam-flow-complete, seam-record-start, seam-record-stop, seam-volume-feedback, seam-license-activated, seam-trial-started`.

### 5.6 "Show on code window" suppression

`_isSuppressedByCodeApp` is driven by the frontmost app's bundle id against this list **[bin]**:

```
com.apple.Terminal, com.googlecode.iterm2, dev.warp.Warp-Stable,
com.mitchellh.ghostty, com.microsoft.VSCode, com.todesktop.230313mzl4w4u92   ← Cursor
```
(`alacritty` / `org.alacritty` also appear, in the `$TERM_PROGRAM` table.) Default behaviour: **hide** the island when you're already looking at the agent; `codeEventsShowOnCodeApp` turns it back on.

---

## 6. Caffeinate

Not `caffeinate(8)`. Seam links IOKit and calls the power-assertion API directly **[bin]**:

```
$ nm -u /Applications/Seam.app/Contents/MacOS/Seam | grep -i IOPM
_IOPMAssertionCreateWithName
_IOPMAssertionRelease
__swift_FORCE_LOAD_$_swiftIOKit

$ otool -L … | grep -i iokit
  /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit
  /usr/lib/swift/libswiftIOKit.dylib (weak)

$ strings … | grep PreventUser
PreventUserIdleSystemSleep
```

So: `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Seam is keeping coding agents awake" as CFString, &assertionID)`, released via `IOPMAssertionRelease`. `CaffeineController` holds `_isCaffeinated` + `assertionID` **[bin]**.

`PreventUserIdleSystemSleep` keeps the **machine** awake but lets the **display** sleep — the right choice for background agents (`caffeinate -i` equivalent, not `-d`).

⚠️ **Correction to the earlier analysis:** the strings `Inserted new assertion`, `system assertion`, `user-initiated assertion` are **not** caffeinate-related. They sit inside `Seam/FocusModeResolver.swift` next to `process == "donotdisturbd" AND eventMessage CONTAINS "modeIdentifier"` and `com.apple.focus.activity-manager` — they are `log show` **predicate fragments** used to detect Focus-mode changes. **[bin]**

`codeEventsCaffeineDance` drives `CaffeineDance` / `CaffeinatedSourceIcon` — *"Agent icon sways and shifts colors while your Mac is held awake."* The pixel-shader-ish fields on the alert view (`currentStage, currentColor, currentPixelSize, currentGridSpacing, slotLayers, activeLayers, animating`) suggest the stage glyph is a Metal/CALayer effect whose colour and grid spacing are driven by the stage. *(inference)*

---

## 7. Recommended design for Notch

### 7.1 Event transport — use a Unix domain socket, with distributed notifications as fallback

Seam's distributed-notification approach costs **one `osascript -l JavaScript` launch per hook event**, and Claude Code fires `PreToolUse` + `PostToolUse` for every single tool call. JXA startup is ~80–150 ms and pulls in the whole ObjC bridge. Cursor *blocks its agent loop* on the hook. That's a real tax.

**Recommended:**

```
~/Library/Application Support/Notch/code-events.sock   (SOCK_DGRAM, mode 0600)
```

Hook shim (no interpreter beyond the shell, no fork to osascript):

```bash
#!/bin/bash
# Notch code-events hook. MUST NEVER block the agent.
exec 2>/dev/null
payload="$(/bin/cat)"
printf '%s' "$payload" | /usr/bin/nc -U -u -w0 "$HOME/Library/Application Support/Notch/code-events.sock" &
exit 0
```

* **SOCK_DGRAM** means no connect handshake and no blocking if Notch is dead — the datagram is simply dropped.
* Send the **raw hook JSON**, unmodified, plus `$TERM_PROGRAM` and an `agent` discriminator. Do the stage mapping **in Swift**, not in the shim — then a stage-mapping change ships with the app instead of requiring a hook reinstall (Seam's mapping is frozen into three shell scripts on disk).
* Keep `NSDistributedNotificationCenter` as a **secondary** listener for the same payload, so a user who already has a JXA-style shim (or a future sandboxed variant) still works.
* Never write anything to stdout. Never exit non-zero. Claude Code parses stdout JSON **on every exit code** — a stray byte becomes a visible `hook error` in the user's transcript.

Fallback for `nc -U -u` portability concerns: a tiny `notch-hook` helper binary shipped in `Contents/MacOS/` that does `socket(AF_UNIX, SOCK_DGRAM)` + `sendto` in ~20 lines of C. That is strictly better than `nc` and removes the background `&`.

### 7.2 Which events to register

| Agent | Register | Why |
|---|---|---|
| Claude Code | `UserPromptSubmit`, `PreToolUse` (`matcher: ""`), `PostToolUse` (`""`), **`PermissionRequest`**, **`Notification`** (`matcher: "permission_prompt\|idle_prompt"`), `Stop`, `SubagentStop`, `SessionEnd` | `PermissionRequest` is the *instant* "needs you" signal Seam lacks. `SessionEnd` clears stale sessions. |
| Codex | `UserPromptSubmit`, `PreToolUse` (`matcher "*"`), `PostToolUse` (`"*"`), **`PermissionRequest`**, `Stop`, `SessionEnd` | same shape; `PermissionRequest` exists here too |
| Cursor | `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `afterFileEdit`, `stop` | Cursor blocks on hooks — keep the list minimal and `timeout: 5` as Seam does |

**Do not** register Codex's legacy `notify` — it is a single-slot key already contested by other tools on this machine.

New island state Seam doesn't have:

```
.waiting(tool: String?, since: Date)   ← PermissionRequest / Notification:permission_prompt
```
Render it distinctly (amber, pulsing, and — critically — *name the tool*, which `PermissionRequest.tool_input` gives you and `Notification` does not).

### 7.3 Installation

* **Claude Code**: read-modify-write `~/.claude/settings.json`, merging into `hooks` without disturbing other keys. Preserve formatting where possible; the file holds the user's whole config. Mark ownership by using an absolute path under `~/.notch/hooks/` so removal is an exact-match filter.
* **Codex**: write a delimited block in `~/.codex/config.toml` exactly like Seam's `# === managed by Notch.app … (begin/end) ===`, plus `[features] hooks = true`. **Then tell the user to run `/hooks` in Codex to trust the new hook** — otherwise it is silently skipped. Consider surfacing "Codex hooks installed — run /hooks to approve" as an island alert.
* **Cursor**: merge into `~/.cursor/hooks.json`, preserving `"version": 1` and any existing entries (other tools append to the same arrays).
* Re-verify on every launch and on `NSWorkspace.didActivateApplicationNotification` for the agent's terminal — Seam has an open question here and apparently only installs on toggle. A cheap mtime check on the three config files is enough.

### 7.4 Usage polling

| Source | Method | Interval |
|---|---|---|
| **Claude (preferred)** | `statusLine` command → `rate_limits.five_hour/seven_day.{used_percentage, resets_at}` | push, free, no auth |
| **Claude (fallback)** | `GET api.anthropic.com/api/oauth/usage` | **≥ 5 min** while an agent is active, **15 min** idle, never under 60 s |
| **Claude sparkline** | scan `~/.claude/projects/**/*.jsonl`, mtime-cached hourly buckets | on activity + every 5 min |
| **Codex** | `codex app-server` → `account/rateLimits/read` | 5 min active / 15 min idle; also opportunistically parse `rate_limits` out of the newest rollout line, which is free |
| **Cursor** | `/api/usage-summary`, then legacy `/api/usage?user=` | 10 min; these are undocumented and fragile |

Plus, for every source, **a one-shot refresh scheduled at each window's `resetsAt`** (Seam's `boundaryTask`). And a refresh on `NSWorkspace.didWakeNotification`, since timers don't fire while asleep.

Rate-limit hygiene, all evidence-backed:
* Always send `User-Agent: claude-code/<detected version>`; detect via `claude --version` and cache it. Missing UA ⇒ punitive 429 bucket with no `Retry-After`.
* Treat 429 as "gate this source for ≥ 15 min" — don't retry-storm.
* 5 s request timeout (what the CLI itself uses).
* Spawn `codex app-server` at most once per refresh, kill it after the response, and correlate strictly by JSON-RPC `id` (unsolicited notifications interleave).

### 7.5 Token refresh policy

* **Never refresh Claude's token.** Claude Code owns the `Claude Code-credentials` Keychain item and rewrites it on refresh; a second writer racing it is how you log the user out. Read `expiresAt`; if the token is expired, show "usage unavailable — open Claude Code" rather than refreshing. If you *must* refresh, do a compare-and-swap write and accept that `refresh_token` may not rotate.
* Prefer the **status-line transport**, which sidesteps tokens entirely.
* **Codex**: never touch `auth.json`; let `codex app-server` handle auth. It also covers the `keyring` and `ephemeral` credential stores where the file doesn't exist.
* **Cursor**: read-only on `state.vscdb`; open with `?immutable=1` / `-readonly` so you can't corrupt Cursor's DB. Reject a JWT with <60 s of life and fall back to the no-credential state.

### 7.6 What to show with no credentials

Four distinct empty states, not one:

| Situation | Island / pane |
|---|---|
| Agent not installed | hide the row entirely; in Settings, "Claude Code not found" with an install link |
| Installed, hooks not registered | "Enable activity for Claude Code" toggle; for Codex add "run `/hooks` in Codex to approve" |
| Hooks live, usage unavailable (no token / 429 / expired) | show **activity** normally; replace the usage bar with a dimmed dash and a tooltip carrying the precise reason — copy Seam's granularity: *No OAuth token in Keychain* / *No Cursor session, sign in to the Cursor app* / *Codex CLI not found* |
| Nothing ever seen | Insights-style empty state: **No coding activity yet** · *See live activity when Claude Code, Codex or Cursor are working.* |

Never block the activity island on usage. They are independent capabilities, and usage is the one that breaks.

### 7.7 Caffeinate

`IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn, "Notch is keeping coding agents awake", &id)` on first non-terminal stage; `IOPMAssertionRelease` when every tracked session reaches `completed`/`failed` **and** a grace period (~2 min) elapses. Add a hard ceiling (e.g. 4 h) so a wedged hook can't pin the machine awake forever — and always release in `applicationWillTerminate` and on an explicit menu toggle.

### 7.8 Suggested module layout

```
NotchKit/Sources/CodeAgentShared/    CodeEvent, CodeEventStage, UsageWindow, UsageData  (Sendable models)
NotchKit/Sources/CodeAgentClient/    HookSocketServer, DistributedNotificationBridge,
                                     ClaudeStatusLineSource, ClaudeOAuthProbe,
                                     CodexAppServerProbe, CursorWebProbe,
                                     ClaudeTranscriptScanner, CodexRolloutScanner,
                                     UsageRefreshCoordinator (poll + boundary + wake)
NotchKit/Sources/CodeAgentFeature/   CodeEventStateMachine (debounce / stage-hold / auto-dismiss),
                                     CodeAgentViewModel, peek + expanded SwiftUI views
NotchKit/Sources/CodeAgentInstall/   ClaudeCodeInstaller, CodexInstaller, CursorInstaller
```
Mirrors the existing `NowPlayingShared` / `NowPlayingClient` / `MusicFeature` split, and keeps the state machine — the only genuinely tricky part — unit-testable with a fake clock, exactly like `IslandPresenterTests` does today.

---

## 8. Open questions

1. Exact debounce / stage-hold / auto-dismiss durations in Seam — no numeric literals are recoverable from `strings`. Would need runtime observation.
2. `CodeCompactStyle` raw values (the `CodeCompactStyleSelector` card options) and the label for `codeEventsShowInfo`.
3. Whether `/api/oauth/usage` returns `resets_at` as ISO-8601 (CodexBar decodes `String?`) or epoch seconds (the status-line path is unambiguously epoch seconds). **Not verified live** — the sandbox blocked the credentialed call. Decode permissively: accept both.
4. Whether Seam re-installs hooks when a user edits `~/.claude/settings.json` by hand. No file-watcher strings found; `ClaudeCodeInstaller` references `UserPromptSubmit` and `.claude/settings.json` directly.
5. Cursor `/api/usage-summary`'s exact shape — Seam's `unrecognized usage summary shape` error and its lower-cased alias table imply it has changed more than once.
