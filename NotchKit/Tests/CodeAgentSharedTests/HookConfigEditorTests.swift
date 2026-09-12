import Testing
import Foundation
@testable import CodeAgentShared

// MARK: - Fixtures

private enum Fixture {
    static let notchCommand = "/Applications/Notch.app/Contents/MacOS/notch-hook claude"
    static let notchCodexCommand = "/Applications/Notch.app/Contents/MacOS/notch-hook codex"
    static let notchCursorCommand = "/Applications/Notch.app/Contents/MacOS/notch-hook cursor"

    /// Trimmed copy of the real `~/.claude/settings.json` on this machine (Seam-managed entries
    /// plus unrelated user keys). Read-only fixture — the real file is never touched.
    static let claudeSettingsWithSeam = """
    {
      "model" : "opus",
      "theme" : "dark",
      "permissions" : { "allow" : ["Bash(git status)"] },
      "hooks" : {
        "PostToolUse" : [
          { "hooks" : [ { "command" : "/Users/me/.seam/hooks/seam-claude-code.sh", "type" : "command" } ],
            "matcher" : "" }
        ],
        "PreToolUse" : [
          { "hooks" : [ { "command" : "/Users/me/.seam/hooks/seam-claude-code.sh", "type" : "command" } ],
            "matcher" : "" }
        ],
        "Stop" : [
          { "hooks" : [ { "command" : "/Users/me/.seam/hooks/seam-claude-code.sh", "type" : "command" } ] }
        ],
        "UserPromptSubmit" : [
          { "hooks" : [ { "command" : "/Users/me/.seam/hooks/seam-claude-code.sh", "type" : "command" } ] }
        ]
      }
    }
    """

    /// A user's own hook that Notch must never disturb.
    static let claudeSettingsWithUserHook = """
    {
      "hooks" : {
        "PreToolUse" : [
          { "matcher" : "Bash",
            "hooks" : [ { "type" : "command", "command" : "/usr/local/bin/my-audit.sh", "timeout" : 30 } ] }
        ],
        "SessionStart" : [
          { "hooks" : [ { "type" : "command", "command" : "/usr/local/bin/greet.sh" } ] }
        ]
      },
      "statusLine" : { "type" : "command", "command" : "ccstatus" }
    }
    """

    /// Shape of `~/.codex/config.toml` around Seam's managed block (lines 1923-1945 on this machine).
    static let codexConfigWithSeam = """
    model = "gpt-5-codex"

    [features]
    hooks = true

    # === managed by Seam.app - code event hooks (begin) ===
    [[hooks.UserPromptSubmit]]
    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "/Users/me/.seam/hooks/seam-codex-hook.sh"

    [[hooks.PreToolUse]]
    matcher = "*"
    [[hooks.PreToolUse.hooks]]
    type = "command"
    command = "/Users/me/.seam/hooks/seam-codex-hook.sh"

    [[hooks.Stop]]
    [[hooks.Stop.hooks]]
    type = "command"
    command = "/Users/me/.seam/hooks/seam-codex-hook.sh"
    # === managed by Seam.app - code event hooks (end) ===

    [tui]
    notifications = true

    """

    static let codexConfigPlain = """
    model = "gpt-5-codex"
    approval_policy = "on-request"

    [features]
    hooks = true

    [mcp_servers.context7]
    command = "npx"

    """

    /// Verbatim shape of `~/.cursor/hooks.json` as Seam wrote it.
    static let cursorHooksWithSeam = """
    {
      "hooks" : {
        "afterFileEdit" : [ { "command" : "/Users/me/.seam/hooks/seam-cursor-hook.sh", "timeout" : 5 } ],
        "beforeSubmitPrompt" : [ { "command" : "/Users/me/.seam/hooks/seam-cursor-hook.sh", "timeout" : 5 } ],
        "postToolUse" : [ { "command" : "/Users/me/.seam/hooks/seam-cursor-hook.sh", "timeout" : 5 } ],
        "preToolUse" : [ { "command" : "/Users/me/.seam/hooks/seam-cursor-hook.sh", "timeout" : 5 } ],
        "stop" : [ { "command" : "/Users/me/.seam/hooks/seam-cursor-hook.sh", "timeout" : 5 } ]
      },
      "version" : 1
    }
    """
}

// MARK: - JSON helpers

private func parse(_ json: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let dictionary = object as? [String: Any] else {
        throw HookConfigError.invalidStructure("root")
    }
    return dictionary
}

/// Re-serializes with the same options the editor uses, so round-trip tests compare content,
/// not incidental whitespace.
private func normalized(_ json: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func hooksDictionary(_ json: String) throws -> [String: Any] {
    try (parse(json)["hooks"] as? [String: Any]) ?? [:]
}

private func claudeGroups(_ json: String, event: String) throws -> [[String: Any]] {
    let array = try hooksDictionary(json)[event] as? [[String: Any]]
    return array ?? []
}

/// Every `command` string anywhere in the config, regardless of nesting.
private func allCommands(_ json: String) throws -> [String] {
    var found: [String] = []
    func walk(_ value: Any) {
        if let dictionary = value as? [String: Any] {
            if let command = dictionary["command"] as? String { found.append(command) }
            for nested in dictionary.values { walk(nested) }
        } else if let array = value as? [Any] {
            for nested in array { walk(nested) }
        }
    }
    walk(try parse(json))
    return found
}

// MARK: - Claude

@Suite struct HookConfigEditorClaudeTests {
    @Test func markerConstant() {
        #expect(HookConfigEditor.marker == "managed by Notch")
    }

    @Test func installOnEmptyObjectCreatesEveryEvent() throws {
        let output = try HookConfigEditor.installClaude(settingsJSON: "{}", command: Fixture.notchCommand)
        let hooks = try hooksDictionary(output)
        #expect(Set(hooks.keys) == Set([
            "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PermissionRequest", "Notification", "Stop", "SessionEnd",
        ]))

        for event in HookConfigEditor.claudeEvents {
            let groups = try claudeGroups(output, event: event)
            #expect(groups.count == 1, "\(event) should hold exactly one Notch group")
            let group = try #require(groups.first)
            let handlers = try #require(group["hooks"] as? [[String: Any]])
            #expect(handlers.count == 1)
            #expect(handlers[0]["type"] as? String == "command")
            #expect(handlers[0]["command"] as? String == "\(Fixture.notchCommand) # managed by Notch")
        }
    }

    @Test func matcherIsPresentOnlyOnToolEvents() throws {
        let output = try HookConfigEditor.installClaude(settingsJSON: "{}", command: Fixture.notchCommand)
        for event in ["PreToolUse", "PostToolUse", "PermissionRequest"] {
            let group = try #require(claudeGroups(output, event: event).first)
            #expect(group["matcher"] as? String == "", "\(event) needs a match-all matcher")
        }
        for event in ["UserPromptSubmit", "Notification", "Stop", "SessionEnd"] {
            let group = try #require(claudeGroups(output, event: event).first)
            #expect(group["matcher"] == nil, "\(event) must not carry a matcher")
        }
    }

    @Test func installIsIdempotent() throws {
        let once = try HookConfigEditor.installClaude(settingsJSON: "{}", command: Fixture.notchCommand)
        let twice = try HookConfigEditor.installClaude(settingsJSON: once, command: Fixture.notchCommand)
        #expect(once == twice)
    }

    @Test func reinstallReplacesAStaleCommandPath() throws {
        let old = try HookConfigEditor.installClaude(settingsJSON: "{}", command: "/Volumes/Old/notch-hook claude")
        let new = try HookConfigEditor.installClaude(settingsJSON: old, command: Fixture.notchCommand)
        let commands = try allCommands(new)
        #expect(commands.contains(where: { $0.contains("/Volumes/Old") }) == false)
        #expect(commands.allSatisfy({ $0 == "\(Fixture.notchCommand) # managed by Notch" }))
    }

    @Test func installRemovesSeamEntriesAndKeepsUnrelatedKeys() throws {
        let output = try HookConfigEditor.installClaude(
            settingsJSON: Fixture.claudeSettingsWithSeam,
            command: Fixture.notchCommand
        )
        let installedCommands = try allCommands(output)
        #expect(installedCommands.contains(where: { $0.contains(".seam/hooks") }) == false)

        let root = try parse(output)
        #expect(root["model"] as? String == "opus")
        #expect(root["theme"] as? String == "dark")
        #expect((root["permissions"] as? [String: Any]) != nil)

        // Seam's group is gone, ours took its place — not appended next to it.
        #expect(try claudeGroups(output, event: "PreToolUse").count == 1)
    }

    @Test func installPreservesAForeignUserHook() throws {
        let output = try HookConfigEditor.installClaude(
            settingsJSON: Fixture.claudeSettingsWithUserHook,
            command: Fixture.notchCommand
        )
        let preToolUse = try claudeGroups(output, event: "PreToolUse")
        #expect(preToolUse.count == 2)
        let userGroup = try #require(preToolUse.first { $0["matcher"] as? String == "Bash" })
        let userHandlers = try #require(userGroup["hooks"] as? [[String: Any]])
        #expect(userHandlers[0]["command"] as? String == "/usr/local/bin/my-audit.sh")
        #expect(userHandlers[0]["timeout"] as? Int == 30)

        // An event Notch does not manage is untouched.
        #expect(try claudeGroups(output, event: "SessionStart").count == 1)
        // Unrelated top-level keys survive.
        let statusLine = try parse(output)["statusLine"] as? [String: Any]
        #expect(statusLine != nil)
    }

    @Test func removeAfterInstallRestoresTheOriginal() throws {
        let original = try normalized(Fixture.claudeSettingsWithUserHook)
        let installed = try HookConfigEditor.installClaude(settingsJSON: original, command: Fixture.notchCommand)
        let removed = try HookConfigEditor.removeClaude(settingsJSON: installed)
        #expect(removed == original)
    }

    @Test func removeDropsEmptyEventArraysAndTheEmptyHooksDictionary() throws {
        let installed = try HookConfigEditor.installClaude(settingsJSON: "{}", command: Fixture.notchCommand)
        let removed = try HookConfigEditor.removeClaude(settingsJSON: installed)
        #expect(try parse(removed).keys.contains("hooks") == false)
        #expect(removed == (try normalized("{}")))
    }

    @Test func removeLeavesSeamEntriesAlone() throws {
        let installed = try HookConfigEditor.installClaude(
            settingsJSON: Fixture.claudeSettingsWithSeam,
            command: Fixture.notchCommand
        )
        // Put a Seam entry back by hand: remove() must only delete Notch-marked entries.
        let withSeamAgain = try HookConfigEditor.removeClaude(settingsJSON: Fixture.claudeSettingsWithSeam)
        let seamCommands = try allCommands(withSeamAgain)
        #expect(seamCommands.contains(where: { $0.contains(".seam/hooks") }))

        let removed = try HookConfigEditor.removeClaude(settingsJSON: installed)
        let leftovers = try allCommands(removed)
        #expect(leftovers.contains(where: { $0.contains(HookConfigEditor.marker) }) == false)
    }

    @Test func removeKeepsForeignHooks() throws {
        let installed = try HookConfigEditor.installClaude(
            settingsJSON: Fixture.claudeSettingsWithUserHook,
            command: Fixture.notchCommand
        )
        let removed = try HookConfigEditor.removeClaude(settingsJSON: installed)
        let preToolUse = try claudeGroups(removed, event: "PreToolUse")
        #expect(preToolUse.count == 1)
        #expect(preToolUse[0]["matcher"] as? String == "Bash")
    }

    @Test func emptyInputIsTreatedAsAnEmptyObject() throws {
        let output = try HookConfigEditor.installClaude(settingsJSON: "   \n", command: Fixture.notchCommand)
        #expect(try hooksDictionary(output).count == HookConfigEditor.claudeEvents.count)
    }

    @Test func unparsableJSONThrows() {
        #expect(throws: HookConfigError.invalidJSON) {
            _ = try HookConfigEditor.installClaude(settingsJSON: "{ not json", command: Fixture.notchCommand)
        }
        #expect(throws: HookConfigError.invalidJSON) {
            _ = try HookConfigEditor.removeClaude(settingsJSON: "{ not json")
        }
    }

    @Test func nonObjectRootThrows() {
        #expect(throws: HookConfigError.invalidStructure("root")) {
            _ = try HookConfigEditor.installClaude(settingsJSON: "[1, 2]", command: Fixture.notchCommand)
        }
    }

    @Test func nonObjectHooksValueThrows() {
        #expect(throws: HookConfigError.invalidStructure("hooks")) {
            _ = try HookConfigEditor.installClaude(settingsJSON: #"{"hooks": 42}"#, command: Fixture.notchCommand)
        }
    }

    @Test func nonArrayEventValueThrows() {
        #expect(throws: HookConfigError.invalidStructure("hooks.PreToolUse")) {
            _ = try HookConfigEditor.installClaude(
                settingsJSON: #"{"hooks": {"PreToolUse": {"matcher": ""}}}"#,
                command: Fixture.notchCommand
            )
        }
    }
}

// MARK: - Codex

@Suite struct HookConfigEditorCodexTests {
    private func block(command: String) -> String {
        """
        # === managed by Notch (begin) ===
        [[hooks.UserPromptSubmit]]
        [[hooks.UserPromptSubmit.hooks]]
        type = "command"
        command = "\(command)"

        [[hooks.PreToolUse]]
        matcher = "*"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "\(command)"

        [[hooks.PostToolUse]]
        matcher = "*"
        [[hooks.PostToolUse.hooks]]
        type = "command"
        command = "\(command)"

        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = "\(command)"
        # === managed by Notch (end) ===
        """
    }

    @Test func installOnEmptyStringWritesOnlyTheBlock() {
        let output = HookConfigEditor.installCodex(configTOML: "", command: Fixture.notchCodexCommand)
        #expect(output == block(command: Fixture.notchCodexCommand) + "\n")
    }

    @Test func installAppendsAfterABlankLineAndPreservesEverythingElse() {
        let output = HookConfigEditor.installCodex(
            configTOML: Fixture.codexConfigPlain,
            command: Fixture.notchCodexCommand
        )
        let expected = Fixture.codexConfigPlain.trimmingTrailingNewlines() + "\n\n"
            + block(command: Fixture.notchCodexCommand) + "\n"
        #expect(output == expected)
        #expect(output.hasPrefix("model = \"gpt-5-codex\"\napproval_policy = \"on-request\"\n"))
    }

    @Test func installRemovesSeamBlockAndKeepsSurroundingTables() {
        let output = HookConfigEditor.installCodex(
            configTOML: Fixture.codexConfigWithSeam,
            command: Fixture.notchCodexCommand
        )
        #expect(!output.contains("managed by Seam.app"))
        #expect(!output.contains(".seam/hooks"))
        #expect(output.contains("[features]\nhooks = true"))
        #expect(output.contains("[tui]\nnotifications = true"))
        #expect(output.hasPrefix("model = \"gpt-5-codex\"\n"))
        #expect(output.hasSuffix(block(command: Fixture.notchCodexCommand) + "\n"))
    }

    @Test func installIsIdempotent() {
        let once = HookConfigEditor.installCodex(
            configTOML: Fixture.codexConfigPlain,
            command: Fixture.notchCodexCommand
        )
        let twice = HookConfigEditor.installCodex(configTOML: once, command: Fixture.notchCodexCommand)
        #expect(once == twice)
    }

    @Test func reinstallReplacesAStaleCommandPath() {
        let old = HookConfigEditor.installCodex(configTOML: "", command: "/Volumes/Old/notch-hook codex")
        let new = HookConfigEditor.installCodex(configTOML: old, command: Fixture.notchCodexCommand)
        #expect(!new.contains("/Volumes/Old"))
        #expect(new == block(command: Fixture.notchCodexCommand) + "\n")
    }

    @Test func removeRestoresTheOriginal() {
        let installed = HookConfigEditor.installCodex(
            configTOML: Fixture.codexConfigPlain,
            command: Fixture.notchCodexCommand
        )
        #expect(HookConfigEditor.removeCodex(configTOML: installed) == Fixture.codexConfigPlain)
    }

    @Test func removeOnEmptyConfigYieldsEmptyString() {
        let installed = HookConfigEditor.installCodex(configTOML: "", command: Fixture.notchCodexCommand)
        #expect(HookConfigEditor.removeCodex(configTOML: installed) == "")
    }

    @Test func removeWithoutABlockIsAByteForByteNoOp() {
        #expect(HookConfigEditor.removeCodex(configTOML: Fixture.codexConfigPlain) == Fixture.codexConfigPlain)
        #expect(HookConfigEditor.removeCodex(configTOML: "") == "")
    }

    /// A config saved with Windows line endings leaves a `\r` on every marker line; trimming
    /// only `.whitespaces` would miss it and leave the stale block sitting next to the new one.
    @Test func removeFindsMarkersInACRLFConfig() {
        let installed = HookConfigEditor.installCodex(
            configTOML: Fixture.codexConfigPlain, command: Fixture.notchCodexCommand)
        let crlf = installed.replacingOccurrences(of: "\n", with: "\r\n")

        let stripped = HookConfigEditor.removeCodex(configTOML: crlf)
        #expect(!stripped.contains(HookConfigEditor.codexBeginMarker))
        #expect(!stripped.contains("notch-hook codex"))
        #expect(stripped.contains("[features]"))  // the user's own content survives

        // And a re-install over CRLF content leaves exactly one managed block.
        let reinstalled = HookConfigEditor.installCodex(configTOML: crlf, command: Fixture.notchCodexCommand)
        #expect(reinstalled.components(separatedBy: HookConfigEditor.codexBeginMarker).count - 1 == 1)
    }

    @Test func removeLeavesSeamsBlockAlone() {
        #expect(HookConfigEditor.removeCodex(configTOML: Fixture.codexConfigWithSeam)
            == Fixture.codexConfigWithSeam)
    }

    @Test func commandIsTOMLEscaped() {
        let raw = #"/Apps/My "Notch".app/Contents/MacOS/notch-hook codex\ "#
        let output = HookConfigEditor.installCodex(configTOML: "", command: raw)
        #expect(output.contains(#"command = "/Apps/My \"Notch\".app/Contents/MacOS/notch-hook codex\\ ""#))
        #expect(!output.contains("\"/Apps/My \"Notch\""))
    }
}

// MARK: - Cursor

@Suite struct HookConfigEditorCursorTests {
    private func cursorEntries(_ json: String, event: String) throws -> [[String: Any]] {
        let array = try hooksDictionary(json)[event] as? [[String: Any]]
        return array ?? []
    }

    @Test func installOnEmptyStringCreatesVersionOneAndEveryEvent() throws {
        let output = try HookConfigEditor.installCursor(hooksJSON: "", command: Fixture.notchCursorCommand)
        #expect(try parse(output)["version"] as? Int == 1)
        #expect(try Set(hooksDictionary(output).keys) == Set([
            "beforeSubmitPrompt", "preToolUse", "postToolUse", "afterFileEdit", "stop",
        ]))
        for event in HookConfigEditor.cursorEvents {
            let entries = try cursorEntries(output, event: event)
            #expect(entries.count == 1)
            // No trailing shell comment: it is unverified whether Cursor runs hooks through a shell.
            #expect(entries[0]["command"] as? String == Fixture.notchCursorCommand)
            #expect(entries[0]["timeout"] as? Int == 5)
        }
    }

    @Test func installIsIdempotent() throws {
        let once = try HookConfigEditor.installCursor(hooksJSON: "{}", command: Fixture.notchCursorCommand)
        let twice = try HookConfigEditor.installCursor(hooksJSON: once, command: Fixture.notchCursorCommand)
        #expect(once == twice)
    }

    @Test func reinstallReplacesAStaleCommandPath() throws {
        let old = try HookConfigEditor.installCursor(hooksJSON: "", command: "/Volumes/Old/notch-hook cursor")
        let new = try HookConfigEditor.installCursor(hooksJSON: old, command: Fixture.notchCursorCommand)
        let commands = try allCommands(new)
        #expect(commands.contains(where: { $0.contains("/Volumes/Old") }) == false)
        #expect(commands.allSatisfy({ $0 == Fixture.notchCursorCommand }))
    }

    @Test func installRemovesSeamEntries() throws {
        let output = try HookConfigEditor.installCursor(
            hooksJSON: Fixture.cursorHooksWithSeam,
            command: Fixture.notchCursorCommand
        )
        let commands = try allCommands(output)
        #expect(commands.contains(where: { $0.contains(".seam/hooks") }) == false)
        #expect(try cursorEntries(output, event: "stop").count == 1)
        #expect(try parse(output)["version"] as? Int == 1)
    }

    @Test func installPreservesForeignEntriesAndKeys() throws {
        let input = """
        {
          "version" : 1,
          "hooks" : {
            "preToolUse" : [ { "command" : "/usr/local/bin/other.sh", "timeout" : 10 } ],
            "sessionStart" : [ { "command" : "/usr/local/bin/start.sh" } ]
          },
          "somethingElse" : true
        }
        """
        let output = try HookConfigEditor.installCursor(hooksJSON: input, command: Fixture.notchCursorCommand)
        let preToolUse = try cursorEntries(output, event: "preToolUse")
        #expect(preToolUse.count == 2)
        #expect(preToolUse.contains(where: { $0["command"] as? String == "/usr/local/bin/other.sh" }))
        #expect(try cursorEntries(output, event: "sessionStart").count == 1)
        #expect(try parse(output)["somethingElse"] as? Bool == true)
    }

    @Test func removeAfterInstallRestoresTheOriginal() throws {
        let original = try normalized("""
        {
          "version" : 1,
          "hooks" : {
            "preToolUse" : [ { "command" : "/usr/local/bin/other.sh", "timeout" : 10 } ]
          }
        }
        """)
        let installed = try HookConfigEditor.installCursor(hooksJSON: original, command: Fixture.notchCursorCommand)
        #expect(try HookConfigEditor.removeCursor(hooksJSON: installed) == original)
    }

    @Test func removeDropsEmptyHooksButKeepsVersion() throws {
        let installed = try HookConfigEditor.installCursor(hooksJSON: "", command: Fixture.notchCursorCommand)
        let removed = try HookConfigEditor.removeCursor(hooksJSON: installed)
        #expect(try parse(removed)["version"] as? Int == 1)
        #expect(try parse(removed).keys.contains("hooks") == false)
    }

    @Test func removeLeavesSeamEntriesAlone() throws {
        let removed = try HookConfigEditor.removeCursor(hooksJSON: Fixture.cursorHooksWithSeam)
        let commands = try allCommands(removed)
        #expect(commands.contains(where: { $0.contains(".seam/hooks") }))
    }

    @Test func unparsableJSONThrows() {
        #expect(throws: HookConfigError.invalidJSON) {
            _ = try HookConfigEditor.installCursor(hooksJSON: "nope", command: Fixture.notchCursorCommand)
        }
        #expect(throws: HookConfigError.invalidJSON) {
            _ = try HookConfigEditor.removeCursor(hooksJSON: "nope")
        }
    }

    @Test func nonArrayEventValueThrows() {
        #expect(throws: HookConfigError.invalidStructure("hooks.stop")) {
            _ = try HookConfigEditor.installCursor(
                hooksJSON: #"{"version": 1, "hooks": {"stop": "nope"}}"#,
                command: Fixture.notchCursorCommand
            )
        }
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var copy = self
        while copy.hasSuffix("\n") { copy.removeLast() }
        return copy
    }
}
