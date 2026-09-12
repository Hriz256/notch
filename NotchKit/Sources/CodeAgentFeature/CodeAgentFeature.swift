import AppKit
import CodeAgentShared
import Foundation
import IslandCore
import Observation
import SwiftUI
import os

/// The "Code" island feature: hooks, events, usage polling and the island views.
///
/// Settings and the hook installer are built in `init` rather than in `activate`, because
/// the status menu reads and writes them whether or not the island is currently on — both
/// are inert until something calls them (the installer touches no file until `install` or
/// `reconcile`, and `CodeSettings` only reads `UserDefaults`).
@MainActor
@Observable
public final class CodeAgentFeature: IslandFeature {
    public let id = CodeAgentViewModel.featureID

    /// User preferences, shared with the status menu.
    public let settings: CodeSettings
    /// Hook config editor, shared with the status menu and the island's context menu.
    public let installer: HookInstaller

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "code.feature")

    @ObservationIgnored private var receiver: EventReceiver?
    @ObservationIgnored private var tracker: SessionTracker?
    @ObservationIgnored private var usage: UsageRefreshCoordinator?
    @ObservationIgnored private var caffeinator: Caffeinator?
    @ObservationIgnored private var model: CodeAgentViewModel?

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
        self.settings = CodeSettings(installedAgents: CodeSettings.detectInstalledAgents(home: home))
        self.installer = HookInstaller(
            homeDirectory: home,
            commandBase: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        )
    }

    // MARK: - Lifecycle

    public func activate(presenter: any IslandPresenting) {
        deactivate()

        installHooksForEnabledAgents()

        let tracker = SessionTracker(clock: TaskClock())
        let usage = UsageRefreshCoordinator(
            providers: makeProviders(),
            sparkline: makeSparkline(),
            clock: TaskClock()
        )
        let caffeinator = Caffeinator()
        let model = CodeAgentViewModel(
            presenter: presenter,
            clock: TaskClock(),
            settings: settings,
            tracker: tracker,
            usage: usage,
            caffeinator: caffeinator,
            sound: { NSSound(named: "Glass")?.play() },
            viewFactory: Self.viewFactory
        )
        model.hooks = installer
        model.syncHookStates()

        let receiver = EventReceiver { [weak model] event in model?.handle(event) }

        self.tracker = tracker
        self.usage = usage
        self.caffeinator = caffeinator
        self.model = model
        self.receiver = receiver

        receiver.start()
        usage.start()
        logger.info("Code feature activated")
    }

    public func deactivate() {
        // The observer has to go first: an event landing mid-teardown would re-present the
        // island the view model is in the middle of dismissing.
        receiver?.stop()
        receiver = nil
        usage?.stop()
        usage = nil
        model?.teardown()
        model = nil
        tracker?.reset()
        tracker = nil
        caffeinator?.set(false)
        caffeinator = nil
    }

    // MARK: - Status-menu surface

    public func isAgentEnabled(_ agent: Agent) -> Bool { settings.isEnabled(agent) }

    /// Switching an agent on installs its hooks; switching it off removes them. Hooks are
    /// the only way an agent can report anything, so the two are the same decision.
    public func setAgentEnabled(_ agent: Agent, _ enabled: Bool) {
        guard settings.isEnabled(agent) != enabled else { return }
        settings.setEnabled(agent, enabled)
        setHooks(agent, installed: enabled)
        // The island may be showing the agent that was just switched off.
        if !enabled, settings.currentAgent == agent, let fallback = settings.enabledAgents.first {
            model?.selectAgent(fallback)
        }
        model?.syncHookStates()
        model?.refreshPresentation()
    }

    /// Codex ignores `[hooks]` until the user approves them with `/hooks` in its TUI.
    public var codexNeedsTrust: Bool { installer.codexNeedsTrust }

    /// Per-agent stage filters, mirrored from the island's context menu so they can also be
    /// changed without waiting for a card to be on screen. Written through the feature rather
    /// than straight into `settings` so the island re-derives immediately.
    public func showsStage(_ agent: Agent, _ stage: Stage) -> Bool { settings.showsStage(agent, stage) }

    public func setShowsStage(_ agent: Agent, _ stage: Stage, _ on: Bool) {
        settings.setShowsStage(agent, stage, on)
        model?.refreshPresentation()
    }

    public func showWhenIdle(_ agent: Agent) -> Bool { settings.showWhenIdle(agent) }

    public func setShowWhenIdle(_ agent: Agent, _ on: Bool) {
        settings.setShowWhenIdle(agent, on)
        model?.refreshPresentation()
    }

    // MARK: - Hooks

    /// Repairs hook commands that point at an older copy of the app, then installs hooks
    /// for every enabled agent that has none yet (which is what "first enable" looks like).
    private func installHooksForEnabledAgents() {
        installer.refreshState()
        do {
            try installer.reconcile()
        } catch {
            logger.error("hook reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
        for agent in settings.enabledAgents where installer.state[agent] == .notInstalled {
            setHooks(agent, installed: true)
        }
    }

    private func setHooks(_ agent: Agent, installed: Bool) {
        do {
            if installed { try installer.install(agent) } else { try installer.uninstall(agent) }
        } catch {
            // `HookInstaller` already logged the reason and parked it in `state`.
            logger.error("hooks \(installed ? "install" : "remove", privacy: .public) failed for \(agent.rawValue, privacy: .public)")
        }
    }

    // MARK: - Usage

    /// Claude is always polled — it is the feature's primary agent and its credentials may
    /// appear at any time. The other two only when their CLI or app is actually present,
    /// so an uninstalled agent never spawns a subprocess or a request.
    private func makeProviders() -> [any UsageProvider] {
        let installed = CodeSettings.detectInstalledAgents(home: home)
        var providers: [any UsageProvider] = [
            ClaudeUsageProvider(
                home: home,
                claudeVersion: { [home] in await ClaudeVersionDetector.detect(home: home) }
            )
        ]
        if installed.contains(.codex) { providers.append(CodexUsageProvider(home: home)) }
        if installed.contains(.cursor) { providers.append(CursorUsageProvider(home: home)) }
        return providers
    }

    private func makeSparkline() -> ClaudeSparkline {
        ClaudeSparkline(
            root: home.appendingPathComponent(".claude/projects"),
            cacheURL: home.appendingPathComponent(
                "Library/Application Support/Notch/claude-usage-cache.json"
            )
        )
    }

    private static let viewFactory = CodeViewFactory(
        compactLeading: { AnyView(CodeCompactLeading(model: $0)) },
        compactTrailing: { AnyView(CodeCompactTrailing(model: $0)) },
        expandedIdle: { AnyView(CodeExpandedView(model: $0)) },
        expandedActivity: { AnyView(CodeActivityView(model: $0)) }
    )
}
