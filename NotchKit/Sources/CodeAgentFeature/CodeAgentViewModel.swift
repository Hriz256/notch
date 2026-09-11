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
    public static let expandedSize = CGSize(width: 380, height: 170)
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

    // MARK: - Private state

    @ObservationIgnored private var mainID: PresentationID?
    @ObservationIgnored private var alertID: PresentationID?
    @ObservationIgnored private var alertToken: ScheduledToken?
    @ObservationIgnored private var tickToken: ScheduledToken?
    /// The finished session the current alert is about, kept so the views can render its
    /// stage for as long as the alert is up.
    @ObservationIgnored private var alertingSession: SessionTracker.Session?
    /// `session key → lastEventAt of the finish we already alerted about`. Keyed by the
    /// event time so a revived session that finishes again alerts again.
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
    public func handle(_ event: AgentEvent) {
        tracker.handle(event)
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

    // MARK: - Refresh

    /// Recomputes both presentations from the tracker, the usage coordinator and the settings.
    ///
    /// Usage results and session expiry arrive on their own schedules, so the read of both is
    /// wrapped in `withObservationTracking`: the next change to either schedules one more
    /// refresh, which re-arms the tracking. Callers never have to poll.
    public func refreshPresentation() {
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
        displayedAgent = active?.agent ?? settings.currentAgent

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

    /// The finished session that still needs an alert, marking it as claimed. `nil` when the
    /// latest finish was already alerted about (a refresh must not re-fire the chime).
    private func claimFinishedSession() -> SessionTracker.Session? {
        alertedFinishes = alertedFinishes.filter { tracker.sessions[$0.key] != nil }

        guard let finished = tracker.latestFinished else { return nil }
        let key = SessionTracker.key(agent: finished.agent, sessionID: finished.id)
        guard alertedFinishes[key] != finished.lastEventAt else { return nil }
        alertedFinishes[key] = finished.lastEventAt
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
        visibleStage = driver.stage
    }

    private func updateElapsed(_ active: SessionTracker.Session?) {
        guard let active else {
            elapsed = 0
            stopTicking()
            return
        }
        elapsed = max(0, now().timeIntervalSince(active.startedAt))
    }

    // MARK: - The main presentation

    private func updateMain(_ active: SessionTracker.Session?) {
        guard let active else {
            guard settings.showWhenIdle(displayedAgent), displayedUsage != nil else {
                dismissMain()
                return
            }
            showMain(priority: .background, expanded: viewFactory.expandedIdle(self))
            return
        }
        // A running session can only be analyzing, thinking, creating or waiting — the
        // finished stages leave `activeSession` by construction.
        showMain(
            priority: active.stage == .waiting ? .alert : .activity,
            expanded: viewFactory.expandedActivity(self)
        )
    }

    /// Keeps one presentation id for the whole life of the feature. `Presentation.priority`
    /// is immutable, so a priority change means a fresh value with the *same* id.
    private func showMain(priority: Priority, expanded: AnyView) {
        let presentation = Presentation(
            id: mainID ?? PresentationID(),
            featureID: Self.featureID,
            priority: priority,
            style: .peek,
            leading: viewFactory.compactLeading(self),
            trailing: viewFactory.compactTrailing(self),
            expanded: expanded,
            expandedSize: Self.expandedSize
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
        logger.debug("alerting \(session.stage.rawValue, privacy: .public) for \(session.agent.rawValue, privacy: .public)")

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
                expandedSize: Self.expandedSize
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

    public func startTicking() {
        guard tickToken == nil else { return }
        tick()
    }

    public func stopTicking() {
        tickToken?.cancel()
        tickToken = nil
    }

    private func tick() {
        guard let active = tracker.activeSession else {
            stopTicking()
            return
        }
        elapsed = max(0, now().timeIntervalSince(active.startedAt))
        tickToken = clock.schedule(after: .seconds(1)) { [weak self] in
            guard let self, tickToken != nil else { return }
            tick()
        }
    }
}
