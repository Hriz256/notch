import Testing
import Foundation
import CodeAgentShared
@testable import CodeAgentFeature

/// Every test works in a throwaway home directory: the real `~/.claude`,
/// `~/.codex` and `~/.cursor` are never read or written.
@MainActor
final class HookInstallerTests {
    private let home: URL
    private let commandBase = URL(fileURLWithPath: "/Applications/Notch.app/Contents/MacOS")

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    private func installer(base: URL? = nil) -> HookInstaller {
        HookInstaller(homeDirectory: home, commandBase: base ?? commandBase)
    }

    private func url(_ agent: Agent) -> URL {
        switch agent {
        case .claude: home.appendingPathComponent(".claude/settings.json")
        case .codex: home.appendingPathComponent(".codex/config.toml")
        case .cursor: home.appendingPathComponent(".cursor/hooks.json")
        }
    }

    private func write(_ text: String, _ agent: Agent) throws {
        let target = url(agent)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
    }

    private func read(_ agent: Agent) throws -> String {
        try String(contentsOf: url(agent), encoding: .utf8)
    }

    /// `JSONSerialization` writes paths as `\/Applications\/…`; path assertions read better
    /// against the unescaped spelling.
    private func readPaths(_ agent: Agent) throws -> String {
        HookInstaller.unescapingSlashes(try read(agent))
    }

    private func backupExists(_ agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: url(agent).appendingPathExtension("notch.bak").path)
    }

    // MARK: - Install

    @Test func installCreatesMissingClaudeSettingsWithTheCommand() throws {
        let subject = installer()
        try subject.install(.claude)

        let text = try readPaths(.claude)
        #expect(text.contains("/Applications/Notch.app/Contents/MacOS/notch-hook claude"))
        #expect(text.contains(HookConfigEditor.marker))
        #expect(text.contains("PermissionRequest"))
        // Nothing existed to back up, so no `.notch.bak` is left behind.
        #expect(!backupExists(.claude))
        #expect(subject.state[.claude] == .installed)
    }

    @Test func installIsIdempotentByteForByte() throws {
        try write("{\"model\" : \"opus\"}", .claude)
        let subject = installer()
        try subject.install(.claude)
        let first = try read(.claude)
        let backup = try String(
            contentsOf: url(.claude).appendingPathExtension("notch.bak"), encoding: .utf8)

        try subject.install(.claude)
        #expect(try read(.claude) == first)
        // The backup is taken once: it still holds the pre-install content.
        #expect(backup != first)
        #expect(try String(contentsOf: url(.claude).appendingPathExtension("notch.bak"),
                           encoding: .utf8) == backup)
    }

    @Test func installOnAllThreeAgentsWritesEachConfig() throws {
        let subject = installer()
        for agent in Agent.allCases { try subject.install(agent) }

        #expect(try read(.codex).contains(HookConfigEditor.codexBeginMarker))
        #expect(try read(.codex).contains("notch-hook codex"))
        #expect(try read(.cursor).contains("notch-hook cursor"))
        #expect(try read(.cursor).contains("\"version\""))
        #expect(Agent.allCases.allSatisfy { subject.state[$0] == .installed })
    }

    @Test func claudeInstallRemovesSeamEntries() throws {
        let seam = """
        {
          "hooks" : {
            "Stop" : [
              {
                "hooks" : [
                  { "command" : "/Users/me/.seam/hooks/seam-hook stop", "type" : "command" }
                ]
              }
            ],
            "PreToolUse" : [
              {
                "matcher" : "Bash",
                "hooks" : [
                  { "command" : "/Users/me/bin/audit.sh", "timeout" : 30, "type" : "command" }
                ]
              }
            ]
          },
          "model" : "opus"
        }
        """
        try write(seam, .claude)

        let subject = installer()
        try subject.install(.claude)

        let text = try readPaths(.claude)
        #expect(!text.contains(".seam/hooks"))
        #expect(text.contains("/Users/me/bin/audit.sh"))  // the user's own hook survives
        #expect(text.contains("\"model\""))
        #expect(text.contains("notch-hook claude"))
    }

    @Test func codexInstallAddsTheFeaturesHooksFlagExactlyOnce() throws {
        try write("[tui]\nnotifications = true\n", .codex)

        let subject = installer()
        try subject.install(.codex)
        try subject.install(.codex)

        let text = try read(.codex)
        #expect(text.contains("[features]"))
        #expect(text.components(separatedBy: "hooks = true").count - 1 == 1)
        #expect(text.contains("[tui]"))
        // The flag must be declared before the managed block, never inside it.
        let features = try #require(text.range(of: "[features]"))
        let block = try #require(text.range(of: HookConfigEditor.codexBeginMarker))
        #expect(features.lowerBound < block.lowerBound)
        #expect(subject.codexNeedsTrust)
    }

    @Test func codexInstallReusesAnExistingFeaturesTable() throws {
        try write("[features]\nweb_search = true\nhooks = false\n\n[tui]\nx = 1\n", .codex)

        let subject = installer()
        try subject.install(.codex)

        let text = try read(.codex)
        #expect(text.contains("hooks = true"))
        #expect(!text.contains("hooks = false"))
        #expect(text.contains("web_search = true"))
        #expect(text.components(separatedBy: "[features]").count - 1 == 1)
    }

    /// A header only Codex's parser would recognize — a trailing comment, inner spaces —
    /// must be reused, not shadowed by a second `[features]` table.
    @Test(arguments: ["[features]  # notes", "[ features ]", "\t[features]\t"])
    func codexReusesAFeaturesHeaderWhateverItsSpelling(header: String) throws {
        try write("\(header)\nweb_search = true\n\n[tui]\nx = 1\n", .codex)

        let subject = installer()
        try subject.install(.codex)
        try subject.install(.codex)

        let text = try read(.codex)
        #expect(text.contains(header))
        #expect(HookInstaller.isValidCodexConfig(text))
        #expect(text.components(separatedBy: "hooks = true").count - 1 == 1)
        // No second table was appended: the only header is the one the user wrote.
        #expect(text.split(whereSeparator: \.isNewline).count(where: { HookInstaller.isFeaturesHeader(String($0)) }) == 1)
        #expect(text.contains("web_search = true"))
        #expect(subject.state[.codex] == .installed)
    }

    /// `features.hooks = …` at the root is the dotted spelling of the same key: declaring a
    /// `[features]` table next to it is the duplicate definition TOML rejects.
    @Test func codexRewritesARootLevelDottedHooksKeyInPlace() throws {
        try write("features.hooks = false\nfeatures.web_search = true\n\n[tui]\nx = 1\n", .codex)

        let subject = installer()
        try subject.install(.codex)

        let text = try read(.codex)
        #expect(text.contains("features.hooks = true"))
        #expect(!text.contains("features.hooks = false"))
        #expect(!text.contains("[features]"))
        #expect(text.contains("features.web_search = true"))
        #expect(HookInstaller.isValidCodexConfig(text))
        #expect(subject.state[.codex] == .installed)
    }

    @Test func codexInstallIsIdempotentOnADottedHooksKey() throws {
        try write("features.hooks = true\n", .codex)
        let subject = installer()
        try subject.install(.codex)
        let first = try read(.codex)
        try subject.install(.codex)
        #expect(try read(.codex) == first)
    }

    /// A config that already declares `[features]` twice cannot be made valid by an edit, so
    /// nothing is written and the menu says so.
    @Test func codexConfigThatWouldStayInvalidIsNotWritten() throws {
        let broken = "[features]\nweb_search = true\n\n[features]\nhooks = false\n"
        try write(broken, .codex)

        let subject = installer()
        #expect(throws: HookInstaller.InstallError.codexConfigInvalid) { try subject.install(.codex) }

        #expect(try read(.codex) == broken)
        #expect(subject.state[.codex] == .failed("config.toml would become invalid"))
    }

    @Test func codexSanityCheckRejectsDuplicateBlocksAndTables() {
        let command = "/Applications/Notch.app/Contents/MacOS/notch-hook codex"
        let good = HookConfigEditor.installCodex(
            configTOML: HookInstaller.ensuringCodexHooksFeature(""), command: command)
        #expect(HookInstaller.isValidCodexConfig(good))
        // Two managed blocks, or two ways of enabling the feature, are both rejected.
        #expect(!HookInstaller.isValidCodexConfig(good + "\n" + good))
        #expect(!HookInstaller.isValidCodexConfig("features.hooks = true\n" + good))
        #expect(!HookInstaller.isValidCodexConfig(good.replacingOccurrences(of: "[features]", with: "")))
    }

    // MARK: - File hygiene

    /// An atomic write replaces the inode; a config the user locked down to 0600 must not
    /// come back readable by everyone.
    @Test func installPreservesPosixPermissionsOnTheConfigAndTheBackup() throws {
        try write("{}", .claude)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url(.claude).path)

        try installer().install(.claude)

        #expect(mode(url(.claude)) == 0o600)
        #expect(mode(url(.claude).appendingPathExtension("notch.bak")) == 0o600)
    }

    /// A config Notch created itself has no previous content, so a `.notch.bak` full of the
    /// placeholder would only confuse a later restore.
    @Test func installDoesNotBackUpAConfigThatDidNotExist() throws {
        let subject = installer()
        try subject.install(.codex)

        #expect(!backupExists(.codex))
        #expect(subject.state[.codex] == .installed)
    }

    private func mode(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - Failure

    @Test func unparsableJSONFailsAndLeavesTheFileUntouched() throws {
        let broken = "{ this is not json"
        try write(broken, .claude)

        let subject = installer()
        #expect(throws: HookConfigError.invalidJSON) { try subject.install(.claude) }

        #expect(try read(.claude) == broken)
        #expect(!backupExists(.claude))
        if case .failed(let reason) = subject.state[.claude] {
            #expect(reason.contains("settings.json"))
        } else {
            Issue.record("expected .failed, got \(String(describing: subject.state[.claude]))")
        }
    }

    @Test func refreshStateReportsUnparsableConfigAsFailed() throws {
        try write("{ nope", .cursor)
        try write("{}", .claude)

        let subject = installer()
        subject.refreshState()

        #expect(subject.state[.claude] == .notInstalled)
        #expect(subject.state[.codex] == .notInstalled)
        #expect(subject.state[.cursor] != .notInstalled)
        #expect(subject.state[.cursor] != .installed)
    }

    @Test func refreshStateSeesAnInstalledConfig() throws {
        let subject = installer()
        try subject.install(.claude)

        let fresh = installer()
        #expect(fresh.state[.claude] == .notInstalled)
        fresh.refreshState()
        #expect(fresh.state[.claude] == .installed)
        #expect(fresh.state[.codex] == .notInstalled)
    }

    // MARK: - Reconcile

    @Test func reconcileRewritesHooksAfterTheAppMoved() throws {
        let old = installer()
        for agent in Agent.allCases { try old.install(agent) }

        let movedBase = URL(fileURLWithPath: "/Users/me/Desktop/Notch.app/Contents/MacOS")
        let moved = installer(base: movedBase)
        try moved.reconcile()

        for agent in Agent.allCases {
            let text = try readPaths(agent)
            #expect(text.contains("/Users/me/Desktop/Notch.app/Contents/MacOS/notch-hook \(agent.rawValue)"))
            #expect(!text.contains("/Applications/Notch.app/Contents/MacOS/notch-hook"))
            #expect(moved.state[agent] == .installed)
        }
        // Codex keeps exactly one managed block and one feature flag.
        let codex = try read(.codex)
        #expect(codex.components(separatedBy: HookConfigEditor.codexBeginMarker).count - 1 == 1)
        #expect(codex.components(separatedBy: "hooks = true").count - 1 == 1)
    }

    @Test func reconcileLeavesAMatchingInstallUntouched() throws {
        let subject = installer()
        try subject.install(.claude)
        let before = try read(.claude)

        try subject.reconcile()
        #expect(try read(.claude) == before)
    }

    @Test func reconcileIgnoresAgentsThatWereNeverInstalled() throws {
        try write("{ \"model\": \"opus\" }", .claude)

        let subject = installer()
        try subject.reconcile()

        #expect(try read(.claude) == "{ \"model\": \"opus\" }")
        #expect(subject.state[.claude] == .notInstalled)
    }

    // MARK: - Uninstall

    @Test func uninstallRemovesOnlyNotchEntries() throws {
        let subject = installer()
        for agent in Agent.allCases { try subject.install(agent) }
        for agent in Agent.allCases { try subject.uninstall(agent) }

        for agent in Agent.allCases {
            let text = try read(agent)
            #expect(!text.contains("notch-hook"))
            #expect(subject.state[agent] == .notInstalled)
        }
        #expect(!subject.codexNeedsTrust)
        #expect(try read(.codex).contains("hooks = true"))  // the user's feature flag stays
    }

    @Test func uninstallOnAMissingConfigIsANoOp() throws {
        let subject = installer()
        try subject.uninstall(.cursor)
        #expect(subject.state[.cursor] == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: url(.cursor).path))
    }

    @Test func installQuotesACommandPathContainingSpaces() throws {
        let subject = installer(base: URL(fileURLWithPath: "/Users/me/My Apps/Notch.app/Contents/MacOS"))
        try subject.install(.claude)
        #expect(try readPaths(.claude)
            .contains("\\\"/Users/me/My Apps/Notch.app/Contents/MacOS/notch-hook\\\" claude"))
    }
}
