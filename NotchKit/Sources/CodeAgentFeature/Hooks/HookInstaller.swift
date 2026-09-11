import Foundation
import OSLog
import CodeAgentShared

/// Reads, edits and writes the three agents' hook config files.
///
/// All content transforms live in ``HookConfigEditor`` (pure); this type owns the
/// file system side: creating a minimal config when one is missing, taking a
/// one-time `.notch.bak`, writing atomically, and reporting failures through
/// ``state`` so the menu can show "fix ~/.claude/settings.json".
///
/// Nothing here logs file contents — only the agent and a short reason.
@MainActor
public final class HookInstaller {

    /// What the UI shows for one agent.
    public enum InstallState: Equatable, Sendable {
        case notInstalled
        case installed
        /// The config could not be edited; payload is a human-readable reason.
        case failed(String)
    }

    /// `~` in production, a temp directory in tests.
    public let homeDirectory: URL
    /// Directory holding `notch-hook`, i.e. `Bundle.main.bundleURL/Contents/MacOS`.
    public let commandBase: URL

    public private(set) var state: [Agent: InstallState]
    /// True once Codex hooks were installed: Codex additionally requires the user to
    /// approve hooks with `/hooks` in its TUI, so the island shows a one-time hint.
    public private(set) var codexNeedsTrust = false

    private let logger = Logger(subsystem: "app.notch", category: "code.hooks")

    public init(homeDirectory: URL, commandBase: URL) {
        self.homeDirectory = homeDirectory
        self.commandBase = commandBase
        self.state = Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, .notInstalled) })
    }

    // MARK: - Paths and commands

    /// Config file Notch edits for an agent.
    public func configURL(for agent: Agent) -> URL {
        switch agent {
        case .claude: homeDirectory.appendingPathComponent(".claude/settings.json")
        case .codex: homeDirectory.appendingPathComponent(".codex/config.toml")
        case .cursor: homeDirectory.appendingPathComponent(".cursor/hooks.json")
        }
    }

    /// The hook command line: `<commandBase>/notch-hook <agent>`, shell-quoted when the
    /// bundle path contains spaces. The TOML/JSON encoders escape the quotes themselves.
    public func command(for agent: Agent) -> String {
        let path = helperPath
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return "\(quoted) \(agent.rawValue)"
    }

    private var helperPath: String { commandBase.appendingPathComponent("notch-hook").path }

    // MARK: - State

    /// Re-reads all three config files and republishes ``state``.
    public func refreshState() {
        for agent in Agent.allCases {
            guard let text = try? String(contentsOf: configURL(for: agent), encoding: .utf8) else {
                state[agent] = .notInstalled
                continue
            }
            if let reason = parseFailure(text, agent: agent) {
                state[agent] = .failed(reason)
                continue
            }
            state[agent] = Self.containsNotchEntry(text, agent: agent) ? .installed : .notInstalled
        }
    }

    /// Re-installs hooks whose command points at a different copy of the app — which is
    /// what an installed config looks like after the user moved or replaced `Notch.app`.
    /// Agents without a Notch entry are left alone.
    public func reconcile() throws {
        var firstFailure: (any Error)?
        for agent in Agent.allCases {
            guard let text = try? String(contentsOf: configURL(for: agent), encoding: .utf8) else { continue }
            guard Self.containsNotchEntry(text, agent: agent) else { continue }
            state[agent] = .installed
            // Comparing the helper path (not the whole command) keeps the check free of
            // the quoting a path with spaces adds; `JSONSerialization` additionally
            // escapes every "/" as "\/", so the text is unescaped before the compare.
            guard !Self.unescapingSlashes(text).contains(helperPath) else { continue }
            logger.info("hook command moved, re-installing \(agent.rawValue, privacy: .public)")
            do { try install(agent) } catch { firstFailure = firstFailure ?? error }
        }
        if let firstFailure { throw firstFailure }
    }

    // MARK: - Install / uninstall

    public func install(_ agent: Agent) throws {
        let url = configURL(for: agent)
        do {
            let original = (try? String(contentsOf: url, encoding: .utf8)) ?? Self.minimalConfig(for: agent)
            let updated: String
            switch agent {
            case .claude:
                updated = try HookConfigEditor.installClaude(settingsJSON: original, command: command(for: agent))
            case .cursor:
                updated = try HookConfigEditor.installCursor(hooksJSON: original, command: command(for: agent))
            case .codex:
                // `[features] hooks = true` has to sit outside the managed block: the table
                // may already exist elsewhere in config.toml and TOML forbids re-declaring it.
                let base = Self.ensuringCodexHooksFeature(HookConfigEditor.removeCodex(configTOML: original))
                updated = HookConfigEditor.installCodex(configTOML: base, command: command(for: agent))
            }
            try write(updated, to: url, original: original)
            if agent == .codex { codexNeedsTrust = true }
            state[agent] = .installed
            logger.info("installed hooks for \(agent.rawValue, privacy: .public)")
        } catch {
            let reason = reason(for: error, agent: agent)
            state[agent] = .failed(reason)
            logger.error("hook install failed for \(agent.rawValue, privacy: .public): \(reason, privacy: .public)")
            throw error
        }
    }

    /// Removes only Notch's entries. Codex's `[features] hooks = true` is left in place:
    /// the user may have set it themselves, and it is inert without hooks.
    public func uninstall(_ agent: Agent) throws {
        let url = configURL(for: agent)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            state[agent] = .notInstalled
            if agent == .codex { codexNeedsTrust = false }
            return
        }
        do {
            let updated: String
            switch agent {
            case .claude: updated = try HookConfigEditor.removeClaude(settingsJSON: original)
            case .codex: updated = HookConfigEditor.removeCodex(configTOML: original)
            case .cursor: updated = try HookConfigEditor.removeCursor(hooksJSON: original)
            }
            try write(updated, to: url, original: original)
            if agent == .codex { codexNeedsTrust = false }
            state[agent] = .notInstalled
            logger.info("removed hooks for \(agent.rawValue, privacy: .public)")
        } catch {
            let reason = reason(for: error, agent: agent)
            state[agent] = .failed(reason)
            logger.error("hook removal failed for \(agent.rawValue, privacy: .public): \(reason, privacy: .public)")
            throw error
        }
    }

    // MARK: - File I/O

    /// Atomic write, preceded by a one-time backup of whatever was there before.
    private func write(_ text: String, to url: URL, original: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let backup = url.appendingPathExtension("notch.bak")
        if !manager.fileExists(atPath: backup.path) {
            try Data(original.utf8).write(to: backup, options: .atomic)
        }
        guard text != original || !manager.fileExists(atPath: url.path) else { return }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Minimal valid content for a config Notch has to create (spec §4).
    static func minimalConfig(for agent: Agent) -> String {
        switch agent {
        case .claude: "{}"
        case .codex: ""
        case .cursor: "{\"version\": 1, \"hooks\": {}}"
        }
    }

    /// `JSONSerialization` writes `"\/Applications\/…"`; both spellings mean the same path.
    static func unescapingSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }

    static func containsNotchEntry(_ text: String, agent: Agent) -> Bool {
        switch agent {
        case .claude: text.contains(HookConfigEditor.marker)
        case .codex: text.contains(HookConfigEditor.codexBeginMarker)
        case .cursor: text.contains(HookConfigEditor.cursorCommandMarker)
        }
    }

    /// `nil` when the file is fine to edit. Only the JSON configs can be pre-validated;
    /// Codex's TOML is edited as text and never parsed.
    private func parseFailure(_ text: String, agent: Agent) -> String? {
        guard agent != .codex else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return "\(displayPath(agent)) is not valid JSON"
        }
        guard root is [String: Any] else { return "\(displayPath(agent)) is not a JSON object" }
        return nil
    }

    private func reason(for error: any Error, agent: Agent) -> String {
        switch error as? HookConfigError {
        case .invalidJSON:
            "\(displayPath(agent)) is not valid JSON"
        case .invalidStructure(let path):
            "\(displayPath(agent)) has an unexpected \"\(path)\" value"
        case nil:
            "Could not write \(displayPath(agent)): \(error.localizedDescription)"
        }
    }

    /// `~/.claude/settings.json` rather than the absolute path, for menu titles.
    func displayPath(_ agent: Agent) -> String {
        let path = configURL(for: agent).path
        let home = homeDirectory.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - Codex feature flag

    /// Ensures `hooks = true` inside a `[features]` table, creating the table at the end
    /// of the file when it is missing. Codex ignores `[hooks]` without this flag.
    ///
    /// Called on config text that has no managed block, so the table always ends up
    /// *before* the block that `installCodex` appends.
    static func ensuringCodexHooksFeature(_ toml: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" })
        else {
            var base = toml
            while base.hasSuffix("\n") || base.hasSuffix("\r") { base.removeLast() }
            let table = "[features]\nhooks = true\n"
            return base.isEmpty ? table : base + "\n\n" + table
        }

        var index = header + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }  // next table: the key is not there
            if isHooksKey(trimmed) {
                lines[index] = "hooks = true"
                return lines.joined(separator: "\n")
            }
            index += 1
        }
        lines.insert("hooks = true", at: header + 1)
        return lines.joined(separator: "\n")
    }

    /// `hooks = …`, tolerating spacing but not `hooks_something = …`.
    private static func isHooksKey(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("hooks") else { return false }
        let rest = trimmed.dropFirst("hooks".count).drop { $0 == " " || $0 == "\t" }
        return rest.first == "="
    }
}
