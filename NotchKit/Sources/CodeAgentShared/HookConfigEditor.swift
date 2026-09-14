import Foundation

/// Why a hook config could not be edited.
public enum HookConfigError: Error, Equatable {
    /// The file is not valid JSON at all.
    case invalidJSON
    /// The file parses but a key we must edit holds an unexpected type. Payload names the path.
    case invalidStructure(String)
}

/// Pure string transforms that add or remove Notch's managed hook entries in the three agents'
/// config files. No file I/O — `HookInstaller` owns reading, atomic writing and backups.
///
/// **How Notch recognizes its own entries**
/// - *Claude Code*: a trailing `# managed by Notch` shell comment inside the `command` string.
///   Claude Code runs a command hook in *shell form* whenever `args` is omitted (documented), so the
///   comment is inert. It is preferred over an extra JSON key because handler objects are decoded
///   into a closed schema and an unknown key risks a visible "hook error".
/// - *Codex*: a fenced text block between `# === managed by Notch (begin) ===` and `(end) ===`.
///   TOML comments are part of the format, and a whole-block edit keeps the rest of a large
///   `config.toml` byte-for-byte intact.
/// - *Cursor*: the name of the bundled helper executable inside the `command` string
///   (`HookConfigEditor.cursorCommandMarker`). Cursor's docs do not say whether the command runs
///   through a shell, so a trailing `#` comment could turn into literal arguments and break the
///   hook; and its `hooks.json` is schema-validated, so an extra `_notch` key could be rejected.
///   Matching on the executable name changes nothing about how the hook runs, which makes it the
///   only option with no chance of breaking Cursor's agent loop.
public enum HookConfigEditor {
    /// Text that identifies a Notch-managed entry in Claude's `settings.json`.
    public static let marker = "managed by Notch"

    /// Substring of every Seam-managed hook command (their shims live in `~/.seam/hooks`).
    public static let seamCommandMarker = ".seam/hooks"

    /// Substring identifying a Notch-managed entry in Cursor's `hooks.json`: our helper's name.
    public static let cursorCommandMarker = "notch-hook"

    /// Claude Code events Notch installs, in write order.
    public static let claudeEvents = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification", "Stop", "SessionEnd",
    ]

    /// Claude events where a match-all `"matcher": ""` is meaningful; elsewhere it is omitted.
    public static let claudeMatcherEvents = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
    ]

    /// Cursor events Notch installs, in write order.
    public static let cursorEvents = [
        "beforeSubmitPrompt", "preToolUse", "postToolUse", "afterFileEdit", "stop",
    ]

    /// Cursor blocks its agent loop on hooks, so keep Seam's conservative timeout.
    public static let cursorTimeout = 5

    public static let codexBeginMarker = "# === managed by Notch (begin) ==="
    public static let codexEndMarker = "# === managed by Notch (end) ==="
    public static let codexSeamBeginMarker = "# === managed by Seam.app - code event hooks (begin) ==="
    public static let codexSeamEndMarker = "# === managed by Seam.app - code event hooks (end) ==="

    // MARK: - Claude Code (~/.claude/settings.json)

    /// Inserts one Notch hook group per managed event, replacing any previous Notch or Seam entry.
    /// Unrelated keys, events and hook groups survive; whitespace is normalized by the JSON
    /// round-trip (pretty-printed, sorted keys).
    public static func installClaude(settingsJSON: String, command: String) throws -> String {
        var root = try jsonObject(settingsJSON)
        var hooks = try dictionary(root["hooks"], path: "hooks")

        for event in claudeEvents {
            var groups = try groupArray(hooks[event], path: "hooks.\(event)")
            groups = groups.compactMap { pruneClaudeGroup($0, dropping: [marker, seamCommandMarker]) }
            groups.append(claudeGroup(event: event, command: command))
            hooks[event] = groups
        }

        root["hooks"] = hooks
        return try jsonString(root)
    }

    /// Whether every event in ``claudeEvents`` carries a Notch group. `false` for a config
    /// written by an older Notch, before an event was added to the list — the installer
    /// re-installs on that at launch — and for anything that does not parse.
    public static func claudeInstallIsComplete(settingsJSON: String) -> Bool {
        guard let root = try? jsonObject(settingsJSON),
              let hooks = try? dictionary(root["hooks"], path: "hooks")
        else { return false }
        return claudeEvents.allSatisfy { event in
            guard let groups = try? groupArray(hooks[event], path: "hooks.\(event)") else { return false }
            return groups.contains { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { ($0["command"] as? String)?.contains(marker) == true }
            }
        }
    }

    /// Deletes only entries carrying `marker`, then prunes hook groups, event arrays and the
    /// `hooks` dictionary that were left empty. Seam's and the user's own entries stay.
    public static func removeClaude(settingsJSON: String) throws -> String {
        var root = try jsonObject(settingsJSON)
        var hooks = try dictionary(root["hooks"], path: "hooks")

        for (event, value) in hooks {
            let groups = try groupArray(value, path: "hooks.\(event)")
            let kept = groups.compactMap { pruneClaudeGroup($0, dropping: [marker]) }
            hooks[event] = kept.isEmpty ? nil : kept
        }

        if hooks.isEmpty {
            root["hooks"] = nil
        } else {
            root["hooks"] = hooks
        }
        return try jsonString(root)
    }

    private static func claudeGroup(event: String, command: String) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": "\(command) # \(marker)"]],
        ]
        if claudeMatcherEvents.contains(event) { group["matcher"] = "" }
        return group
    }

    /// Removes handlers whose command contains any of `needles`. Returns nil when nothing is left.
    private static func pruneClaudeGroup(_ group: [String: Any], dropping needles: [String]) -> [String: Any]? {
        var group = group
        guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
        let kept = handlers.filter { handler in
            guard let command = handler["command"] as? String else { return true }
            return !needles.contains { command.contains($0) }
        }
        if kept.isEmpty { return nil }
        group["hooks"] = kept
        return group
    }

    // MARK: - Codex CLI (~/.codex/config.toml)

    /// Replaces the managed block (and any Seam block) with a fresh one appended at the end of the
    /// file after a blank line. Everything outside the blocks is preserved byte-for-byte; only the
    /// trailing newlines are normalized to exactly one.
    public static func installCodex(configTOML: String, command: String) -> String {
        var base = removeBlock(configTOML, begin: codexBeginMarker, end: codexEndMarker)
        base = removeBlock(base, begin: codexSeamBeginMarker, end: codexSeamEndMarker)
        base = trimmingTrailingNewlines(base)

        let block = codexBlock(command: command)
        if base.isEmpty { return block + "\n" }
        return base + "\n\n" + block + "\n"
    }

    /// Deletes Notch's block. A config without one comes back unchanged, byte for byte.
    public static func removeCodex(configTOML: String) -> String {
        guard configTOML.contains(codexBeginMarker) else { return configTOML }
        let base = trimmingTrailingNewlines(removeBlock(configTOML, begin: codexBeginMarker, end: codexEndMarker))
        return base.isEmpty ? "" : base + "\n"
    }

    private static func codexBlock(command: String) -> String {
        let escaped = tomlEscape(command)
        // [[hooks.X]] holds only `matcher`; handlers live in the nested [[hooks.X.hooks]].
        // `matcher` is ignored on UserPromptSubmit and Stop, so it is omitted there.
        let events: [(name: String, matcher: String?)] = [
            ("UserPromptSubmit", nil),
            ("PreToolUse", "*"),
            ("PostToolUse", "*"),
            ("Stop", nil),
        ]
        var lines = [codexBeginMarker]
        for (index, event) in events.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("[[hooks.\(event.name)]]")
            if let matcher = event.matcher { lines.append("matcher = \"\(matcher)\"") }
            lines.append("[[hooks.\(event.name).hooks]]")
            lines.append("type = \"command\"")
            lines.append("command = \"\(escaped)\"")
        }
        lines.append(codexEndMarker)
        return lines.joined(separator: "\n")
    }

    /// Drops the marked lines plus any blank lines immediately before them, so repeated installs
    /// cannot accumulate whitespace. An unterminated block is removed through the end of the file.
    ///
    /// Marker lines are trimmed of whitespace *and newlines*: a config saved with CRLF endings
    /// leaves a trailing `\r` on every line, which would otherwise stop the markers from
    /// matching and leave the old block in place next to the new one.
    private static func removeBlock(_ text: String, begin: String, end: String) -> String {
        guard text.contains(begin) else { return text }
        var kept: [Substring] = []
        var inside = false
        for line in lines(of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inside, trimmed == begin {
                inside = true
                while let last = kept.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    kept.removeLast()
                }
                continue
            }
            if inside {
                if trimmed == end { inside = false }
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Splits on any line terminator. `split(separator: "\n")` cannot be used: Swift treats
    /// `"\r\n"` as a *single* `Character`, so a CRLF file would come back as one long line and
    /// the block markers would never match. The price is that editing a CRLF config normalizes
    /// it to LF — which TOML accepts, and which beats leaving a stale block behind.
    public static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    private static func tomlEscape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var copy = text
        while copy.hasSuffix("\n") || copy.hasSuffix("\r") { copy.removeLast() }
        return copy
    }

    // MARK: - Cursor (~/.cursor/hooks.json)

    /// Inserts one `{"command": …, "timeout": 5}` entry per managed event, replacing previous Notch
    /// and Seam entries and creating `"version": 1` when absent.
    public static func installCursor(hooksJSON: String, command: String) throws -> String {
        var root = try jsonObject(hooksJSON)
        if root["version"] == nil { root["version"] = 1 }
        var hooks = try dictionary(root["hooks"], path: "hooks")

        for event in cursorEvents {
            var entries = try groupArray(hooks[event], path: "hooks.\(event)")
            entries = entries.filter { !isCursorEntryManaged($0, needles: [cursorCommandMarker, seamCommandMarker]) }
            entries.append(["command": command, "timeout": cursorTimeout])
            hooks[event] = entries
        }

        root["hooks"] = hooks
        return try jsonString(root)
    }

    /// Deletes only Notch's entries, then prunes empty event arrays and an empty `hooks` object.
    public static func removeCursor(hooksJSON: String) throws -> String {
        var root = try jsonObject(hooksJSON)
        var hooks = try dictionary(root["hooks"], path: "hooks")

        for (event, value) in hooks {
            let entries = try groupArray(value, path: "hooks.\(event)")
            let kept = entries.filter { !isCursorEntryManaged($0, needles: [cursorCommandMarker]) }
            hooks[event] = kept.isEmpty ? nil : kept
        }

        if hooks.isEmpty {
            root["hooks"] = nil
        } else {
            root["hooks"] = hooks
        }
        return try jsonString(root)
    }

    private static func isCursorEntryManaged(_ entry: [String: Any], needles: [String]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return needles.contains { command.contains($0) }
    }

    // MARK: - JSON plumbing

    /// Parses a settings file. Blank input is treated as `{}` so a freshly created file works.
    private static func jsonObject(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            throw HookConfigError.invalidJSON
        }
        guard let root = parsed as? [String: Any] else {
            throw HookConfigError.invalidStructure("root")
        }
        return root
    }

    private static func jsonString(_ root: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                  withJSONObject: root,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else {
            throw HookConfigError.invalidStructure("root")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dictionary(_ value: Any?, path: String) throws -> [String: Any] {
        guard let value, !(value is NSNull) else { return [:] }
        guard let dictionary = value as? [String: Any] else {
            throw HookConfigError.invalidStructure(path)
        }
        return dictionary
    }

    private static func groupArray(_ value: Any?, path: String) throws -> [[String: Any]] {
        guard let value, !(value is NSNull) else { return [] }
        guard let array = value as? [Any] else {
            throw HookConfigError.invalidStructure(path)
        }
        return try array.map { element in
            guard let dictionary = element as? [String: Any] else {
                throw HookConfigError.invalidStructure(path)
            }
            return dictionary
        }
    }
}
