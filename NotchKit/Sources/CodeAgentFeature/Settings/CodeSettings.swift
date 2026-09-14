import Foundation
import Observation
import CodeAgentShared

/// User preferences for the Code feature, backed by `UserDefaults`.
///
/// Values are mirrored into an observable in-memory cache so SwiftUI views can
/// observe them; every setter writes through to `UserDefaults` immediately.
///
/// Keys (spec §2): `code.<agent>.enabled`, `code.<agent>.showAnalyzing`,
/// `…showThinking`, `…showCreating`, `code.<agent>.showWhenIdle`,
/// `code.playCompleteSound`, `code.showPace`, `code.caffeinate`, `code.currentAgent`.
@MainActor
@Observable
public final class CodeSettings {

    // MARK: - Keys

    public static func enabledKey(_ agent: Agent) -> String { "code.\(agent.rawValue).enabled" }
    public static func showWhenIdleKey(_ agent: Agent) -> String { "code.\(agent.rawValue).showWhenIdle" }
    /// `nil` for stages the user cannot hide (waiting, completed, failed).
    public static func stageKey(_ agent: Agent, _ stage: Stage) -> String? {
        guard let suffix = stageSuffix(stage) else { return nil }
        return "code.\(agent.rawValue).\(suffix)"
    }
    public static let playCompleteSoundKey = "code.playCompleteSound"
    public static let showPaceKey = "code.showPace"
    public static let caffeinateKey = "code.caffeinate"
    public static let currentAgentKey = "code.currentAgent"

    /// Stages the user can hide; the rest are always shown.
    public static let filterableStages: [Stage] = [.analyzing, .thinking, .creating]

    private static func stageSuffix(_ stage: Stage) -> String? {
        switch stage {
        case .analyzing: "showAnalyzing"
        case .thinking: "showThinking"
        case .creating: "showCreating"
        case .waiting, .completed, .failed, .ended: nil
        }
    }

    // MARK: - Storage

    @ObservationIgnored private let defaults: UserDefaults
    /// Every boolean setting, primed in `init` and kept in sync by the setters.
    private var flags: [String: Bool]
    private var agent: Agent

    /// - Parameter installedAgents: which agents were detected on this machine.
    ///   Only consulted the **first** time a given agent's `enabled` key is written:
    ///   installing Codex later must not silently switch its hooks on, and disabling
    ///   an agent must survive the next launch.
    public init(defaults: UserDefaults = .standard, installedAgents: Set<Agent>) {
        self.defaults = defaults

        for candidate in Agent.allCases {
            let key = Self.enabledKey(candidate)
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(candidate == .claude || installedAgents.contains(candidate), forKey: key)
        }

        var flags: [String: Bool] = [:]
        for candidate in Agent.allCases {
            flags[Self.enabledKey(candidate)] = defaults.bool(forKey: Self.enabledKey(candidate))
            for stage in Self.filterableStages {
                guard let key = Self.stageKey(candidate, stage) else { continue }
                flags[key] = defaults.object(forKey: key) as? Bool ?? true
            }
            let idle = Self.showWhenIdleKey(candidate)
            flags[idle] = defaults.object(forKey: idle) as? Bool ?? true
        }
        flags[Self.playCompleteSoundKey] = defaults.object(forKey: Self.playCompleteSoundKey) as? Bool ?? true
        flags[Self.showPaceKey] = defaults.object(forKey: Self.showPaceKey) as? Bool ?? true
        flags[Self.caffeinateKey] = defaults.object(forKey: Self.caffeinateKey) as? Bool ?? false
        self.flags = flags

        self.agent = defaults.string(forKey: Self.currentAgentKey).flatMap(Agent.init(rawValue:)) ?? .claude
    }

    // MARK: - Per agent

    public func isEnabled(_ agent: Agent) -> Bool { flags[Self.enabledKey(agent)] ?? false }

    public func setEnabled(_ agent: Agent, _ on: Bool) { set(Self.enabledKey(agent), on) }

    /// Whether a stage is allowed to change what the island shows. Stages outside
    /// ``filterableStages`` are never hidden.
    public func showsStage(_ agent: Agent, _ stage: Stage) -> Bool {
        guard let key = Self.stageKey(agent, stage) else { return true }
        return flags[key] ?? true
    }

    public func setShowsStage(_ agent: Agent, _ stage: Stage, _ on: Bool) {
        guard let key = Self.stageKey(agent, stage) else { return }
        set(key, on)
    }

    public func showWhenIdle(_ agent: Agent) -> Bool { flags[Self.showWhenIdleKey(agent)] ?? true }

    public func setShowWhenIdle(_ agent: Agent, _ on: Bool) { set(Self.showWhenIdleKey(agent), on) }

    /// Agents the user turned on, in `Agent.allCases` order.
    public var enabledAgents: [Agent] { Agent.allCases.filter(isEnabled) }

    // MARK: - Global

    public var playCompleteSound: Bool {
        get { flags[Self.playCompleteSoundKey] ?? true }
        set { set(Self.playCompleteSoundKey, newValue) }
    }

    public var showPace: Bool {
        get { flags[Self.showPaceKey] ?? true }
        set { set(Self.showPaceKey, newValue) }
    }

    public var caffeinate: Bool {
        get { flags[Self.caffeinateKey] ?? false }
        set { set(Self.caffeinateKey, newValue) }
    }

    /// Agent whose usage the expanded view shows.
    public var currentAgent: Agent {
        get { agent }
        set {
            agent = newValue
            defaults.set(newValue.rawValue, forKey: Self.currentAgentKey)
        }
    }

    private func set(_ key: String, _ value: Bool) {
        flags[key] = value
        defaults.set(value, forKey: key)
    }

    // MARK: - Detection

    /// Which agents look installed. Claude Code is always offered (it is the feature's
    /// primary agent); Codex and Cursor are only offered when their CLI or app is present.
    public nonisolated static func detectInstalledAgents(home: URL) -> Set<Agent> {
        var found: Set<Agent> = [.claude]
        let manager = FileManager.default

        if manager.fileExists(atPath: home.appendingPathComponent(".codex").path)
            || executableExists("codex", home: home) {
            found.insert(.codex)
        }
        if manager.fileExists(atPath: "/Applications/Cursor.app")
            || manager.fileExists(atPath: home.appendingPathComponent(".cursor").path) {
            found.insert(.cursor)
        }
        return found
    }

    /// The app is not launched from a shell, so `PATH` is useless here: probe the
    /// three directories a CLI like Codex is actually installed into.
    private nonisolated static func executableExists(_ name: String, home: URL) -> Bool {
        let directories = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".local/bin"),
        ]
        return directories.contains {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent(name).path)
        }
    }
}
