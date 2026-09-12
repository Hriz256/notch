import CodeAgentShared
import Foundation
import IslandCore
import Observation
import SwiftUI
import os

/// Builds the island views for the Code feature. Injected so the view model is testable
/// without SwiftUI rendering, exactly like `MusicViewFactory`.
@MainActor
public struct CodeViewFactory {
    /// Compact leading slot — the agent icon.
    public var compactLeading: (CodeAgentViewModel) -> AnyView
    /// Compact trailing slot — the usage ring while idle, the stage glyph while working.
    public var compactTrailing: (CodeAgentViewModel) -> AnyView
    /// Expanded panel while no session is running: usage bars and the sparkline.
    public var expandedIdle: (CodeAgentViewModel) -> AnyView
    /// Expanded panel while a session is running, waiting, or has just finished.
    public var expandedActivity: (CodeAgentViewModel) -> AnyView

    public init(
        compactLeading: @escaping (CodeAgentViewModel) -> AnyView,
        compactTrailing: @escaping (CodeAgentViewModel) -> AnyView,
        expandedIdle: @escaping (CodeAgentViewModel) -> AnyView,
        expandedActivity: @escaping (CodeAgentViewModel) -> AnyView
    ) {
        self.compactLeading = compactLeading
        self.compactTrailing = compactTrailing
        self.expandedIdle = expandedIdle
        self.expandedActivity = expandedActivity
    }

    public static let placeholder = CodeViewFactory(
        compactLeading: { _ in AnyView(EmptyView()) },
        compactTrailing: { _ in AnyView(EmptyView()) },
        expandedIdle: { _ in AnyView(EmptyView()) },
        expandedActivity: { _ in AnyView(EmptyView()) }
    )
}

/// Folds the session tracker, the usage coordinator and the user's settings into island
/// presentations (spec §3.3).
///
/// Two presentations at most are ever alive:
///
/// - **`mainID`** is long lived and mutated *in place*. It carries the idle card
///   (`.background`), the working card (`.activity`) and the waiting prompt (`.alert`).
///   Re-presenting instead of updating would give the panel a new view identity and blink
///   it away and back on every stage change.
/// - **`alertID`** is a short, separate `.alert` with a `ttl` for a completed or failed
///   session. It is separate precisely so the main card can already be back on idle (or on
///   the next session) underneath it.
@MainActor
@Observable
public final class CodeAgentViewModel {
    public static let featureID = FeatureID("code")
    /// The idle card: usage bars plus the sparkline. Also the default for anything that
    /// needs a size before a view model exists.
    public static let expandedSize = CGSize(width: 380, height: 170)
    /// The activity card. Exactly as tall as the idle one: the working panel carries the
    /// same sparkline, and a detail line *replaces* that sparkline rather than adding to
    /// it (see ``CodeActivityView``), so the two variants land on the same budget. Equal
    /// heights also mean the card never resizes as the session moves between stages.
    static let activitySize = expandedSize
    /// How long the completion / failure alert stays up.
    public static let alertDuration: Duration = .seconds(4)

    /// Window lengths assumed when the provider does not report one (spec §3.3 pace rule).
    static let sessionWindowLength: TimeInterval = 5 * 3600
    static let weeklyWindowLength: TimeInterval = 7 * 24 * 3600

    // MARK: - Published state

    /// The agent the island is about: the running session's agent while working, otherwise
    /// whichever agent the user picked.
    public private(set) var displayedAgent: Agent
    /// The last stage that passed the user's stage filter. A hidden stage leaves this
    /// untouched, so the island keeps showing the stage before it.
    public private(set) var visibleStage: Stage?
    /// Seconds since the running session started. Only re-derived at 1 Hz between
    /// ``startTicking()`` and ``stopTicking()``; a plain refresh still snaps it to the truth.
    public private(set) var elapsed: TimeInterval = 0

    public var displayedUsage: AgentUsage? {
        guard case .success(let snapshot) = usage.usage[displayedAgent] else { return nil }
        return snapshot
    }

    public var usageError: UsageError? {
        guard case .failure(let error) = usage.usage[displayedAgent] else { return nil }
        return error
    }

    public var activeSession: SessionTracker.Session? { tracker.activeSession }
    public var activeCount: Int { tracker.activeCount }
    public var isCaffeinating: Bool { caffeinator.isActive }

    /// The session the island is currently about: the running one, or — while a completion
    /// alert is up — the finished one the alert is for. This is what the views render.
    public var displayedSession: SessionTracker.Session? { tracker.activeSession ?? alertingSession }

    /// How tall the expanded card has to be for what the panel is about to draw.
    ///
    /// Read off the same session ``CodeActivityView`` renders, and recomputed on every
    /// ``refreshPresentation()``.
    public var expandedSize: CGSize { Self.expandedSize(for: displayedSession) }

    /// `nil` means the idle panel. Both panels are 170 pt tall — the seam is kept so a
    /// future card that needs less room can shrink without touching the presenter.
    static func expandedSize(for session: SessionTracker.Session?) -> CGSize {
        session == nil ? expandedSize : activitySize
    }

    /// Agents the user switched on, in `Agent.allCases` order; the context menu's "Show" list.
    public var enabledAgents: [Agent] { settings.enabledAgents }
    /// Whether a completed session chimes. Mirrors `code.playCompleteSound`.
    public var playsCompletionSound: Bool { settings.playCompleteSound }
    /// Whether the user asked Notch to hold a power assertion while agents work. Distinct
    /// from ``isCaffeinating``, which is whether the assertion is held *right now*.
    public var caffeinateWhileWorking: Bool { settings.caffeinate }

    /// Daily token totals behind the sparkline; empty when usage is unavailable.
    public var sparkline: [Double] { displayedUsage?.sparkline ?? [] }

    /// Past this, the numbers on screen are old enough to be worth marking (spec §4): a
    /// failing poll otherwise leaves a confident-looking bar that has not moved in hours.
    public static let stalenessThreshold: TimeInterval = 20 * 60

    /// Whether the displayed snapshot was fetched long enough ago to show the stale dot.
    /// `asOf` comes from the panel's own timeline so the dot appears without a refresh.
    public func isUsageStale(asOf date: Date) -> Bool {
        guard let fetchedAt = displayedUsage?.fetchedAt else { return false }
        return date.timeIntervalSince(fetchedAt) > Self.stalenessThreshold
    }

    /// Hook install state per agent, mirrored from ``HookInstaller`` so the context menu
    /// re-renders when it changes (the installer itself is not observable).
    public private(set) var hookStates: [Agent: HookInstaller.InstallState] = [:]

    // MARK: - Collaborators

    @ObservationIgnored private let presenter: any IslandPresenting
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private let settings: CodeSettings
    @ObservationIgnored private let tracker: SessionTracker
    @ObservationIgnored private let usage: UsageRefreshCoordinator
    @ObservationIgnored private let caffeinator: Caffeinator
    @ObservationIgnored private let sound: @MainActor () -> Void
    @ObservationIgnored private let viewFactory: CodeViewFactory
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "code.viewmodel")
    /// Injected after construction by ``CodeAgentFeature`` (the feature owns both), so the
    /// context menu can read and change hook state. `nil` in tests.
    @ObservationIgnored public weak var hooks: HookInstaller?

    // MARK: - Private state

    @ObservationIgnored private var mainID: PresentationID?
    @ObservationIgnored private var alertID: PresentationID?
    @ObservationIgnored private var alertToken: ScheduledToken?
    @ObservationIgnored private var tickToken: ScheduledToken?
    /// How many expanded panels are on screen and want the 1 Hz clock.
    @ObservationIgnored private var visiblePanels = 0
    /// The finished session the current alert is about, kept so the views can render its
    /// stage for as long as the alert is up. Observed (not `@ObservationIgnored`) because
    /// ``displayedSession`` hands it to the views.
    private var alertingSession: SessionTracker.Session?
    /// Set by ``teardown()``. Observation callbacks armed before the teardown can still
    /// fire afterwards; this stops them from re-presenting a dismissed island.
    @ObservationIgnored private var isTornDown = false
    /// `session key → startedAt of the run we already alerted about`. Keyed by the run's
    /// start so a revived session that finishes again alerts again, while the two events
    /// that end one run (Stop, SessionEnd) share a single alert.
    @ObservationIgnored private var alertedFinishes: [String: Date] = [:]
    /// Coalesces the refresh that observation asks for, so one burst of events is one refresh.
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(
        presenter: any IslandPresenting,
        clock: any IslandClock,
        settings: CodeSettings,
        tracker: SessionTracker,
        usage: UsageRefreshCoordinator,
        caffeinator: Caffeinator,
        sound: @escaping @MainActor () -> Void,
        viewFactory: CodeViewFactory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.presenter = presenter
        self.clock = clock
        self.settings = settings
        self.tracker = tracker
        self.usage = usage
        self.caffeinator = caffeinator
        self.sound = sound
        self.viewFactory = viewFactory
        self.now = now
        self.displayedAgent = settings.currentAgent
        // Also arms the observation of the tracker and the usage coordinator.
        refreshPresentation()
    }

    // MARK: - Input

    /// Folds one hook event into the tracker and re-derives the island.
    ///
    /// Events from an agent the user switched off are dropped here rather than filtered
    /// downstream: hooks are removed on disable, but a config Notch could not edit — or an
    /// agent process that was already running — can still send them, and the island must not
    /// come back for an agent the user turned off.
    public func handle(_ event: AgentEvent) {
        guard settings.isEnabled(event.agent) else { return }
        tracker.handle(event)
        // A session that just ended is exactly when today's token total changed, and when
        // the user is most likely to open the panel. The coordinator throttles the rescan.
        if event.stage == .completed || event.stage == .failed { usage.sparklineNeedsRefresh() }
        refreshPresentation()
    }

    public func selectAgent(_ agent: Agent) {
        settings.currentAgent = agent
        refreshPresentation()
    }

    public func toggleCaffeinate() {
        settings.caffeinate.toggle()
        refreshPresentation()
    }

    public func togglePlayCompletionSound() {
        settings.playCompleteSound.toggle()
        refreshPresentation()
    }

    // MARK: - Per-agent visibility (the context menu's per-agent submenu)

    /// Whether a stage is allowed to change what the island shows for `agent`.
    public func showsStage(_ agent: Agent, _ stage: Stage) -> Bool {
        settings.showsStage(agent, stage)
    }

    public func toggleStage(_ agent: Agent, _ stage: Stage) {
        settings.setShowsStage(agent, stage, !settings.showsStage(agent, stage))
        refreshPresentation()
    }

    public func showsWhenIdle(_ agent: Agent) -> Bool { settings.showWhenIdle(agent) }

    public func toggleShowWhenIdle(_ agent: Agent) {
        settings.setShowWhenIdle(agent, !settings.showWhenIdle(agent))
        refreshPresentation()
    }

    /// The menu title for a stage the user may hide. Same wording in the island's context
    /// menu and in the status menu, so the two read as one setting.
    public static func stageMenuTitle(_ stage: Stage) -> String {
        switch stage {
        case .analyzing: "Show Analyzing"
        case .thinking: "Show Thinking"
        case .creating: "Show Creating"
        case .waiting, .completed, .failed: "Show \(stage.rawValue)"
        }
    }

    /// Fetches every agent's usage right now, bypassing the poll cadence.
    public func refreshUsage() {
        usage.refreshNow()
    }

    // MARK: - Hooks

    /// Re-reads the three config files and republishes ``hookStates``.
    public func syncHookStates() {
        hooks?.refreshState()
        hookStates = hooks?.state ?? [:]
    }

    /// Installs or removes Notch's hooks for one agent. Failures are logged and end up in
    /// ``hookStates`` as `.failed`, which is what the menu shows.
    public func setHooksInstalled(_ agent: Agent, _ installed: Bool) {
        guard let hooks else { return }
        do {
            if installed { try hooks.install(agent) } else { try hooks.uninstall(agent) }
        } catch {
            logger.error("hook change failed for \(agent.rawValue, privacy: .public)")
        }
        hookStates = hooks.state
    }

    // MARK: - Teardown

    /// Drops both presentations and every timer. The view model is single-use afterwards:
    /// nothing it observes can bring the island back.
    public func teardown() {
        isTornDown = true
        visiblePanels = 0
        cancelTick()
        observationTask?.cancel()
        observationTask = nil
        alertToken?.cancel()
        alertToken = nil
        alertingSession = nil
        visibleStage = nil
        if let alertID {
            presenter.dismiss(alertID)
            self.alertID = nil
        }
        dismissMain()
        caffeinator.set(false)
    }

    // MARK: - Refresh

    /// Recomputes both presentations from the tracker, the usage coordinator and the settings.
    ///
    /// Usage results and session expiry arrive on their own schedules, so the read of both is
    /// wrapped in `withObservationTracking`: the next change to either schedules one more
    /// refresh, which re-arms the tracking. Callers never have to poll.
    public func refreshPresentation() {
        guard !isTornDown else { return }
        withObservationTracking {
            _ = usage.usage
            _ = tracker.sessions
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        apply()
    }

    private func scheduleRefresh() {
        guard observationTask == nil else { return }
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            observationTask = nil
            refreshPresentation()
        }
    }

    private func apply() {
        let active = tracker.activeSession
        displayedAgent = active?.agent ?? currentEnabledAgent

        let newAlert = claimFinishedSession()
        if let newAlert { alertingSession = newAlert }

        updateVisibleStage(driver: active ?? alertingSession)
        updateElapsed(active)
        updateMain(active)
        if let newAlert { presentAlert(for: newAlert) }

        caffeinator.set(settings.caffeinate && tracker.activeCount > 0)
        // Lets the coordinator poll on its active cadence while agents are running.
        usage.isSessionActive = tracker.activeCount > 0
    }

    /// The user's agent, or — once they switch it off — the first one still enabled. With
    /// nothing enabled this settles on `.claude` and ``updateMain(_:)`` presents nothing:
    /// the views always need *an* agent to render against, even with no card on screen.
    private var currentEnabledAgent: Agent {
        let current = settings.currentAgent
        if settings.isEnabled(current) { return current }
        return settings.enabledAgents.first ?? .claude
    }

    /// The finished session that still needs an alert, marking it as claimed. `nil` when the
    /// latest finish was already alerted about (a refresh must not re-fire the chime).
    private func claimFinishedSession() -> SessionTracker.Session? {
        alertedFinishes = alertedFinishes.filter { tracker.sessions[$0.key] != nil }

        guard let finished = tracker.latestFinished else { return nil }
        let key = SessionTracker.key(agent: finished.agent, sessionID: finished.id)
        // Keyed by `startedAt`, not by the event time: Claude Code reports the end of one run
        // twice (Stop, then SessionEnd), and two chimes four seconds apart for one finished
        // session reads as a bug. A session the user revives gets a fresh `startedAt`, so
        // finishing it again does alert again.
        guard alertedFinishes[key] != finished.startedAt else { return nil }
        alertedFinishes[key] = finished.startedAt
        return finished
    }

    /// Stages the user hid must not change what the island shows: the previous stage stays.
    /// `waiting`, `completed` and `failed` are never filterable.
    private func updateVisibleStage(driver: SessionTracker.Session?) {
        guard let driver else {
            visibleStage = nil
            return
        }
        guard settings.showsStage(driver.agent, driver.stage) else { return }
        guard visibleStage != driver.stage else { return }
        visibleStage = driver.stage
        // The one line that says what the island is showing. Stage and agent only — never
        // the tool arguments or the prompt text the detail line carries.
        logger.info("showing \(driver.stage.rawValue, privacy: .public) for \(driver.agent.rawValue, privacy: .public)")
    }

    private func updateElapsed(_ active: SessionTracker.Session?) {
        guard let active else {
            elapsed = 0
            cancelTick()
            return
        }
        elapsed = max(0, now().timeIntervalSince(active.startedAt))
        // A panel that was already on screen when this session started never saw an
        // `onAppear`, so this is the only place its clock can be restarted.
        if visiblePanels > 0, tickToken == nil { tick() }
    }

    // MARK: - The main presentation

    private func updateMain(_ active: SessionTracker.Session?) {
        guard let active else {
            // An error is as much a reason to show the idle card as a snapshot is: "Open
            // Claude Code to sign in" is only actionable if the user can see it, and
            // presenting nothing is indistinguishable from the feature being off.
            guard settings.isEnabled(displayedAgent),
                  settings.showWhenIdle(displayedAgent),
                  displayedUsage != nil || usageError != nil
            else {
                dismissMain()
                return
            }
            showMain(
                priority: .background,
                expanded: viewFactory.expandedIdle(self),
                size: Self.expandedSize
            )
            return
        }
        // A running session can only be analyzing, thinking, creating or waiting — the
        // finished stages leave `activeSession` by construction.
        showMain(
            priority: active.stage == .waiting ? .alert : .activity,
            expanded: viewFactory.expandedActivity(self),
            size: Self.expandedSize(for: active)
        )
    }

    /// Keeps one presentation id for the whole life of the feature. `Presentation.priority`
    /// is immutable, so a priority change means a fresh value with the *same* id.
    private func showMain(priority: Priority, expanded: AnyView, size: CGSize) {
        let presentation = Presentation(
            id: mainID ?? PresentationID(),
            featureID: Self.featureID,
            priority: priority,
            style: .peek,
            leading: viewFactory.compactLeading(self),
            trailing: viewFactory.compactTrailing(self),
            expanded: expanded,
            expandedSize: size
        )
        if mainID == nil {
            mainID = presentation.id
            presenter.present(presentation)
        } else {
            presenter.update(presentation)
        }
    }

    private func dismissMain() {
        guard let mainID else { return }
        presenter.dismiss(mainID)
        self.mainID = nil
    }

    // MARK: - The completion alert

    private func presentAlert(for session: SessionTracker.Session) {
        // Info rather than debug: this is the event that chimes and steals the island, so
        // it is the first thing anyone looks for in the log. Stage and agent only.
        logger.info("alerting \(session.stage.rawValue, privacy: .public) for \(session.agent.rawValue, privacy: .public)")

        if session.stage == .completed, settings.playCompleteSound { sound() }

        // A second finish while the first alert is up replaces it rather than stacking.
        if let alertID { presenter.dismiss(alertID) }
        let id = PresentationID()
        alertID = id
        presenter.present(
            Presentation(
                id: id,
                featureID: Self.featureID,
                priority: .alert,
                style: .peek,
                ttl: Self.alertDuration,
                leading: viewFactory.compactLeading(self),
                trailing: viewFactory.compactTrailing(self),
                expanded: viewFactory.expandedActivity(self),
                expandedSize: Self.expandedSize(for: session)
            )
        )

        alertToken?.cancel()
        alertToken = clock.schedule(after: Self.alertDuration) { [weak self] in
            guard let self else { return }
            alertToken = nil
            alertingSession = nil
            // The presenter drops it on its own ttl; this is belt and braces so the view
            // model never believes an alert it no longer owns is on screen.
            if let alertID { presenter.dismiss(alertID) }
            alertID = nil
            refreshPresentation()
        }
    }

    // MARK: - Pace

    /// `.slowDown` when the window is burning faster than the clock, `nil` when the user
    /// turned the pace hint off or the window cannot be judged.
    public func pace(for window: UsageWindow?) -> Pace? {
        guard settings.showPace, let window else { return nil }
        let length = window.windowLength
            ?? (window == displayedUsage?.weekly ? Self.weeklyWindowLength : Self.sessionWindowLength)
        return PaceCalculator.pace(
            percent: window.percent,
            resetsAt: window.resetsAt,
            windowLength: length,
            now: now()
        )
    }

    // MARK: - Elapsed ticking (only while the expanded panel is visible)

    /// Balanced against ``stopTicking()``. Both panels carry the same `onAppear`/`onDisappear`
    /// pair, and SwiftUI appears the incoming one *before* it disappears the outgoing one, so
    /// a plain flag would let the panel that is leaving stop the clock the arriving panel had
    /// just started.
    public func startTicking() {
        visiblePanels += 1
        guard tickToken == nil else { return }
        tick()
    }

    public func stopTicking() {
        visiblePanels = max(0, visiblePanels - 1)
        guard visiblePanels == 0 else { return }
        cancelTick()
    }

    /// Stops the clock regardless of how many panels are on screen: there is simply nothing
    /// left to count.
    private func cancelTick() {
        tickToken?.cancel()
        tickToken = nil
    }

    private func tick() {
        guard let active = tracker.activeSession else {
            cancelTick()
            return
        }
        elapsed = max(0, now().timeIntervalSince(active.startedAt))
        tickToken = clock.schedule(after: .seconds(1)) { [weak self] in
            guard let self, tickToken != nil else { return }
            tick()
        }
    }
}
