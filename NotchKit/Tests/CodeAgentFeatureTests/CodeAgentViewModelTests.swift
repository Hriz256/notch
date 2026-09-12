import CodeAgentShared
import Foundation
import IslandCore
import Testing
@testable import CodeAgentFeature

// MARK: - Doubles

/// Local to this suite: the other suites in this target own same-named doubles of their own.
@MainActor
private final class CodeVMPresenter: IslandPresenting {
    var presented: [Presentation] = []
    var updated: [Presentation] = []
    var dismissed: [PresentationID] = []
    var live: [PresentationID: Presentation] = [:]

    func present(_ p: Presentation) {
        presented.append(p)
        live[p.id] = p
    }

    func update(_ p: Presentation) {
        updated.append(p)
        live[p.id] = p
    }

    func dismiss(_ id: PresentationID) {
        dismissed.append(id)
        live.removeValue(forKey: id)
    }
}

@MainActor
private final class CodeVMClock: IslandClock {
    private struct Entry {
        let due: Duration
        let action: @MainActor () -> Void
        let id: Int
    }

    private var entries: [Entry] = []
    private var nextID = 0
    private(set) var now: Duration = .zero

    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    var currentDate: Date { startDate.addingTimeInterval(now.asSeconds) }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let id = nextID
        nextID += 1
        entries.append(Entry(due: now + delay, action: action, id: id))
        return ScheduledToken { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    func advance(by delta: Duration) {
        let target = now + delta
        while let next = entries.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            entries.removeAll { $0.id == next.id }
            next.action()
        }
        now = target
    }
}

private extension Duration {
    var asSeconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

@MainActor
private final class SoundCounter {
    var count = 0
}

/// Answers one scripted result forever; enough for a view-model test, which only cares
/// that a snapshot (or an error) exists for an agent.
private struct StubUsageProvider: UsageProvider {
    let agent: Agent
    let result: Result<AgentUsage, UsageError>

    func fetch() async throws(UsageError) -> AgentUsage {
        switch result {
        case .success(let usage): return usage
        case .failure(let error): throw error
        }
    }
}

private func usage(
    _ agent: Agent,
    percent: Double = 10,
    resetsAt: Date? = nil,
    fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> AgentUsage {
    AgentUsage(
        agent: agent,
        session: UsageWindow(percent: percent, resetsAt: resetsAt, windowLength: 5 * 3600),
        // No `windowLength`, so the view model has to supply the 7 d fallback itself.
        weekly: UsageWindow(
            percent: 20,
            resetsAt: fetchedAt.addingTimeInterval(6 * 24 * 3600),
            windowLength: nil
        ),
        sparkline: [],
        fetchedAt: fetchedAt,
        planLabel: "Max"
    )
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let vm: CodeAgentViewModel
    let presenter: CodeVMPresenter
    let clock: CodeVMClock
    let settings: CodeSettings
    let tracker: SessionTracker
    let coordinator: UsageRefreshCoordinator
    let sound: SoundCounter

    var mainPresentation: Presentation? {
        presenter.presented.first { $0.featureID == CodeAgentViewModel.featureID && $0.ttl == nil }
            .flatMap { presenter.live[$0.id] }
    }

    func event(
        _ stage: Stage,
        agent: Agent = .claude,
        session: String = "s1",
        tool: String? = nil,
        detail: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            agent: agent,
            sessionID: session,
            stage: stage,
            tool: tool,
            detail: detail,
            timestamp: clock.currentDate
        )
    }
}

@MainActor
private func makeFixture(
    results: [Agent: Result<AgentUsage, UsageError>] = [:],
    defaults: UserDefaults
) -> Fixture {
    let presenter = CodeVMPresenter()
    let clock = CodeVMClock()
    let now: @Sendable () -> Date = { MainActor.assumeIsolated { clock.currentDate } }
    let settings = CodeSettings(defaults: defaults, installedAgents: Set(Agent.allCases))
    let tracker = SessionTracker(clock: clock, now: now)
    let coordinator = UsageRefreshCoordinator(
        providers: results.map { StubUsageProvider(agent: $0.key, result: $0.value) },
        sparkline: nil,
        clock: clock,
        now: now
    )
    let sound = SoundCounter()
    let vm = CodeAgentViewModel(
        presenter: presenter,
        clock: clock,
        settings: settings,
        tracker: tracker,
        usage: coordinator,
        caffeinator: Caffeinator(),
        sound: { sound.count += 1 },
        viewFactory: .placeholder,
        now: now
    )
    return Fixture(
        vm: vm,
        presenter: presenter,
        clock: clock,
        settings: settings,
        tracker: tracker,
        coordinator: coordinator,
        sound: sound
    )
}

// MARK: - Tests

@MainActor
final class CodeAgentViewModelTests {
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        suite = "app.notch.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    /// Loads the coordinator so `usage.usage` is populated, then refreshes the view model.
    private func loadUsage(_ f: Fixture) async {
        f.coordinator.start()
        await f.coordinator.settle()
        f.vm.refreshPresentation()
    }

    // MARK: Idle

    @Test func idleWithUsagePresentsOneBackgroundPeek() async throws {
        let f = makeFixture(results: [.claude: .success(usage(.claude))], defaults: defaults)
        await loadUsage(f)

        #expect(f.presenter.presented.count == 1)
        let presentation = try #require(f.mainPresentation)
        #expect(presentation.priority == .background)
        #expect(presentation.style == .peek)
        #expect(presentation.ttl == nil)
        #expect(presentation.featureID == FeatureID("code"))
        // Menus name the card by its title, not the feature id.
        #expect(presentation.title == "Code")
        #expect(presentation.displayTitle == "Code")
        #expect(presentation.expandedSize == CodeAgentViewModel.expandedSize)
        #expect(f.vm.displayedAgent == .claude)
        #expect(f.vm.displayedUsage?.agent == .claude)
        #expect(f.vm.usageError == nil)
        #expect(f.vm.visibleStage == nil)
    }

    @Test func idleWithoutUsagePresentsNothing() {
        let f = makeFixture(defaults: defaults)
        f.vm.refreshPresentation()

        #expect(f.presenter.presented.isEmpty)
        #expect(f.vm.displayedUsage == nil)
    }

    /// A failure the user can act on ("Open Claude Code to sign in") is only useful on
    /// screen, so the idle card is presented for an error exactly as it is for a snapshot.
    @Test func idleWithUsageErrorStillPresentsTheIdleCard() async throws {
        let f = makeFixture(results: [.claude: .failure(.notSignedIn)], defaults: defaults)
        await loadUsage(f)

        let presentation = try #require(f.mainPresentation)
        #expect(presentation.priority == .background)
        #expect(presentation.expandedSize == CodeAgentViewModel.expandedSize)
        #expect(f.vm.displayedUsage == nil)
        #expect(f.vm.usageError == .notSignedIn)
        // The expanded panel swaps both bars for one line that names the fix.
        #expect(CodeUsageBars.message(for: .notSignedIn) == "Open Claude Code to sign in")
        // And the compact slot marks the gap instead of drawing a ring at 0 %.
        #expect(CodeCompactTrailing.slot(for: f.vm) == .unavailable)
    }

    @Test func idleWithUsagePutsTheRingInTheCompactSlot() async {
        let f = makeFixture(results: [.claude: .success(usage(.claude, percent: 42))], defaults: defaults)
        await loadUsage(f)

        #expect(CodeCompactTrailing.slot(for: f.vm) == .ring(42))
    }

    @Test func showWhenIdleOffStillHidesAUsageError() async {
        let f = makeFixture(results: [.claude: .failure(.notSignedIn)], defaults: defaults)
        f.settings.setShowWhenIdle(.claude, false)
        await loadUsage(f)

        #expect(f.presenter.presented.isEmpty)
    }

    /// A snapshot older than 20 minutes is marked; the countdown beside it keeps ticking,
    /// so without the dot the bar would look freshly fetched.
    @Test func staleSnapshotIsMarkedAfterTwentyMinutes() async {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let f = makeFixture(results: [.claude: .success(usage(.claude, fetchedAt: fetchedAt))], defaults: defaults)
        await loadUsage(f)

        #expect(!f.vm.isUsageStale(asOf: fetchedAt.addingTimeInterval(19 * 60)))
        #expect(f.vm.isUsageStale(asOf: fetchedAt.addingTimeInterval(21 * 60)))
    }

    @Test func showWhenIdleOffDismissesTheIdlePresentation() async throws {
        let f = makeFixture(results: [.claude: .success(usage(.claude))], defaults: defaults)
        await loadUsage(f)
        let id = try #require(f.mainPresentation?.id)

        f.settings.setShowWhenIdle(.claude, false)
        f.vm.refreshPresentation()

        #expect(f.presenter.dismissed == [id])
        #expect(f.presenter.live.isEmpty)
    }

    // MARK: Working

    @Test func workingUpdatesTheSamePresentationToActivity() async throws {
        let f = makeFixture(results: [.claude: .success(usage(.claude))], defaults: defaults)
        await loadUsage(f)
        let id = try #require(f.mainPresentation?.id)

        f.vm.handle(f.event(.thinking, tool: "Edit"))

        // The island must not be re-presented: a second presentation would swap the panel.
        #expect(f.presenter.presented.count == 1)
        #expect(f.presenter.live[id]?.priority == .activity)
        #expect(f.presenter.live[id]?.style == .peek)
        #expect(f.presenter.live[id]?.expanded != nil)
        #expect(f.vm.visibleStage == .thinking)
        #expect(f.vm.activeSession?.tool == "Edit")
        #expect(f.vm.activeCount == 1)
    }

    @Test func workingSessionDrivesTheDisplayedAgent() {
        let f = makeFixture(defaults: defaults)
        f.settings.currentAgent = .claude
        f.vm.handle(f.event(.creating, agent: .codex))

        #expect(f.vm.displayedAgent == .codex)
        f.vm.handle(f.event(.completed, agent: .codex))
        #expect(f.vm.displayedAgent == .claude)
    }

    @Test func workingPresentsEvenWithoutUsage() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.analyzing))

        #expect(f.presenter.presented.count == 1)
        #expect(f.presenter.presented[0].priority == .activity)
    }

    @Test func waitingRaisesTheMainPresentationToAlert() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        let id = f.presenter.presented[0].id

        f.vm.handle(f.event(.waiting, tool: "Bash"))

        #expect(f.presenter.presented.count == 1)          // still one, sticky
        #expect(f.presenter.live[id]?.priority == .alert)
        #expect(f.presenter.live[id]?.style == .peek)
        #expect(f.presenter.live[id]?.ttl == nil)          // sticky: the user must answer it
        #expect(f.vm.visibleStage == .waiting)
    }

    /// The working panel carries the sparkline the idle one does, so it is the same 170 pt
    /// card: starting a session must not resize the island.
    @Test func workingPresentationKeepsTheIdleHeight() async throws {
        let f = makeFixture(results: [.claude: .success(usage(.claude))], defaults: defaults)
        await loadUsage(f)
        #expect(f.mainPresentation?.expandedSize.height == 170)

        f.vm.handle(f.event(.thinking, tool: "Bash"))

        let presentation = try #require(f.mainPresentation)
        #expect(presentation.expandedSize == CGSize(width: 380, height: 170))
        #expect(f.vm.expandedSize.height == 170)
    }

    /// A permission prompt carries a detail line, which takes the sparkline's room rather
    /// than the card's — so the height does not move for that either.
    @Test func waitingWithDetailKeepsTheSameHeight() throws {
        let f = makeFixture(defaults: defaults)

        f.vm.handle(f.event(.waiting, tool: "Bash", detail: "Allow Bash to run rm -rf build?"))

        let presentation = try #require(f.mainPresentation)
        #expect(presentation.expandedSize == CGSize(width: 380, height: 170))
        #expect(f.vm.expandedSize.height == 170)
    }

    // MARK: Completion alerts

    @Test func completedPresentsASeparateAlertAndChimes() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        let mainID = f.presenter.presented[0].id

        f.vm.handle(f.event(.completed))

        #expect(f.presenter.presented.count == 2)
        let alert = f.presenter.presented[1]
        #expect(alert.id != mainID)
        #expect(alert.priority == .alert)
        #expect(alert.style == .peek)
        #expect(alert.ttl == CodeAgentViewModel.alertDuration)
        #expect(alert.ttl == .seconds(4))
        #expect(alert.title == "Code")
        #expect(f.vm.visibleStage == .completed)
        #expect(f.sound.count == 1)

        // Idempotent: another refresh must not fire a second chime or a second alert.
        f.vm.refreshPresentation()
        #expect(f.sound.count == 1)
        #expect(f.presenter.presented.count == 2)
    }

    /// Claude Code reports the end of a run twice — Stop, then SessionEnd — and both map to
    /// `.completed`. Two chimes seconds apart for one finished run reads as a bug.
    @Test func aSecondFinishEventForTheSameRunDoesNotChimeAgain() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        f.vm.handle(f.event(.completed))
        #expect(f.sound.count == 1)

        f.clock.advance(by: .seconds(1))
        f.vm.handle(f.event(.completed))

        #expect(f.sound.count == 1)
        #expect(f.presenter.presented.count == 2)
    }

    /// A session the user picks back up is a new run, and its finish is worth announcing.
    @Test func aRevivedSessionFinishingAgainAlertsAgain() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        f.vm.handle(f.event(.completed))
        #expect(f.sound.count == 1)

        f.clock.advance(by: .seconds(2))
        f.vm.handle(f.event(.thinking))
        f.clock.advance(by: .seconds(2))
        f.vm.handle(f.event(.completed))

        #expect(f.sound.count == 2)
        #expect(f.presenter.presented.count(where: { $0.priority == .alert }) == 2)
    }

    @Test func eventsFromADisabledAgentAreIgnored() {
        let f = makeFixture(defaults: defaults)
        f.settings.setEnabled(.codex, false)

        f.vm.handle(f.event(.thinking, agent: .codex, session: "c1"))

        #expect(f.presenter.presented.isEmpty)
        #expect(f.vm.activeSession == nil)
        #expect(f.vm.visibleStage == nil)
    }

    /// With every agent switched off there is nothing the island is about, so it shows
    /// nothing — and the displayed agent falls back to one that is still on.
    @Test func disablingTheDisplayedAgentFallsBackAndThenDismisses() async throws {
        let f = makeFixture(
            results: [.claude: .success(usage(.claude)), .codex: .success(usage(.codex))],
            defaults: defaults
        )
        await loadUsage(f)
        let id = try #require(f.mainPresentation?.id)
        #expect(f.vm.displayedAgent == .claude)

        f.settings.setEnabled(.claude, false)
        f.vm.refreshPresentation()
        #expect(f.vm.displayedAgent == .codex)
        #expect(f.presenter.live[id] != nil)

        for agent in Agent.allCases { f.settings.setEnabled(agent, false) }
        f.vm.refreshPresentation()
        #expect(f.vm.displayedAgent == .claude)  // the placeholder the views render against
        #expect(f.presenter.live.isEmpty)
    }

    @Test func completedDoesNotChimeWhenTheSoundIsOff() {
        let f = makeFixture(defaults: defaults)
        f.settings.playCompleteSound = false
        f.vm.handle(f.event(.thinking))
        f.vm.handle(f.event(.completed))

        #expect(f.sound.count == 0)
        #expect(f.presenter.presented.count == 2)          // the alert still shows
    }

    @Test func failedAlertsWithoutASound() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        f.vm.handle(f.event(.failed))

        #expect(f.sound.count == 0)
        #expect(f.presenter.presented.count == 2)
        #expect(f.presenter.presented[1].priority == .alert)
        #expect(f.vm.visibleStage == .failed)
    }

    @Test func mainPresentationIsBackToIdleAfterTheAlertExpires() async throws {
        let f = makeFixture(results: [.claude: .success(usage(.claude))], defaults: defaults)
        await loadUsage(f)
        let mainID = try #require(f.mainPresentation?.id)

        f.vm.handle(f.event(.thinking))
        #expect(f.presenter.live[mainID]?.priority == .activity)

        f.vm.handle(f.event(.completed))
        let alertID = f.presenter.presented[1].id
        #expect(f.presenter.live[mainID]?.priority == .background)   // already idle again

        f.clock.advance(by: CodeAgentViewModel.alertDuration)
        #expect(f.presenter.dismissed.contains(alertID))
        #expect(f.presenter.live[mainID]?.priority == .background)
        #expect(f.vm.visibleStage == nil)
    }

    // MARK: Stage filter

    @Test func filteredStageKeepsThePreviousVisibleStage() {
        let f = makeFixture(defaults: defaults)
        f.settings.setShowsStage(.claude, .creating, false)

        f.vm.handle(f.event(.thinking))
        #expect(f.vm.visibleStage == .thinking)

        f.vm.handle(f.event(.creating, tool: "Write"))
        #expect(f.vm.visibleStage == .thinking)            // the hidden stage does not show
        #expect(f.vm.activeSession?.stage == .creating)    // …but the truth is still tracked

        // Unhideable stages always come through.
        f.vm.handle(f.event(.waiting))
        #expect(f.vm.visibleStage == .waiting)
    }

    /// The filter applies on top of the dwell: a hidden stage leaves the glyph where it is,
    /// even once the glyph is long past its minimum time on screen.
    @Test func filteredStageKeepsThePreviousGlyph() {
        let f = makeFixture(defaults: defaults)
        f.settings.setShowsStage(.claude, .creating, false)

        f.vm.handle(f.event(.analyzing, tool: "Read"))
        #expect(f.vm.visibleActivity == .reading)

        // Well past the 1.5 s dwell, so only the filter can be holding the magnifier.
        f.clock.advance(by: .seconds(3))
        f.vm.handle(f.event(.creating, tool: "Write"))
        #expect(f.vm.visibleActivity == .reading)
        #expect(f.vm.visibleStage == .analyzing)
        #expect(f.vm.activeSession?.tool == "Write")
    }

    // MARK: Sticky displayed session

    /// The bug: two Claude Code windows interleaving hooks had the island swapping between
    /// them on every event — "то одна покажется, то другая".
    @Test func theIslandStaysWithOneSessionWhileTwoAreWorking() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking, session: "s1"))
        #expect(f.vm.displayedSessionKey == SessionTracker.key(agent: .claude, sessionID: "s1"))

        for _ in 0..<6 {
            f.clock.advance(by: .milliseconds(200))
            f.vm.handle(f.event(.creating, session: "s2", tool: "Edit"))
            #expect(f.vm.displayedSession?.id == "s1")

            f.clock.advance(by: .milliseconds(200))
            f.vm.handle(f.event(.analyzing, session: "s1", tool: "Read"))
            #expect(f.vm.displayedSession?.id == "s1")
        }

        // The second session is still counted — that is what the header's "×2" is for.
        #expect(f.vm.activeCount == 2)
    }

    @Test func theIslandFollowsTheOtherSessionAfterFiveQuietSeconds() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking, session: "s1"))

        f.clock.advance(by: .seconds(1))
        f.vm.handle(f.event(.thinking, agent: .codex, session: "s2"))
        #expect(f.vm.displayedSession?.id == "s1")
        #expect(f.vm.displayedAgent == .claude)

        // Five seconds after `s1`'s last event, with `s2` still working.
        f.clock.advance(by: .seconds(4))
        f.vm.handle(f.event(.creating, agent: .codex, session: "s2", tool: "Edit"))
        #expect(f.vm.displayedSession?.id == "s2")
        #expect(f.vm.displayedAgent == .codex)
    }

    @Test func aFinishedSessionHandsTheIslandToTheOneStillWorking() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking, session: "s1"))
        f.clock.advance(by: .milliseconds(200))
        f.vm.handle(f.event(.thinking, session: "s2"))
        #expect(f.vm.displayedSession?.id == "s1")

        f.clock.advance(by: .milliseconds(200))
        f.vm.handle(f.event(.completed, session: "s1"))

        // The island is about `s2` at once; the completion of `s1` is the separate alert.
        #expect(f.vm.displayedSession?.id == "s2")
        #expect(f.vm.activeCount == 1)
        #expect(f.presenter.presented.count(where: { $0.priority == .alert }) == 1)
    }

    // MARK: Glyph dwell

    /// The timeline from the spec, driven through the view model and its manual clock: a
    /// 100 ms `Read`, an `Edit` right behind it, and then the tool ending for good.
    @Test func theGlyphHoldsItsGroundAndThenFallsBackToTheDots() {
        let f = makeFixture(defaults: defaults)

        f.vm.handle(f.event(.analyzing, tool: "Read"))                 // t = 0
        #expect(f.vm.visibleActivity == .reading)
        #expect(CodeCompactTrailing.slot(for: f.vm) == .activity(.reading))

        f.clock.advance(by: .milliseconds(100))                        // t = 0.1
        f.vm.handle(f.event(.thinking))                                // PostToolUse(Read)
        #expect(f.vm.visibleActivity == .reading)

        f.clock.advance(by: .milliseconds(100))                        // t = 0.2
        f.vm.handle(f.event(.creating, tool: "Edit"))                  // PreToolUse(Edit)
        #expect(f.vm.visibleActivity == .reading)

        f.clock.advance(by: .milliseconds(1200))                       // t = 1.4
        #expect(f.vm.visibleActivity == .reading)

        // The magnifier has had its 1.5 s; the pencil takes over with no new event needed.
        f.clock.advance(by: .milliseconds(100))                        // t = 1.5
        #expect(f.vm.visibleActivity == .editing)

        f.clock.advance(by: .milliseconds(100))                        // t = 1.6
        f.vm.handle(f.event(.thinking))                                // PostToolUse(Edit)
        #expect(f.vm.visibleActivity == .editing)
        #expect(f.vm.visibleStage == .thinking)                        // the stage is honest

        f.clock.advance(by: .milliseconds(1900))                       // t = 3.5
        #expect(f.vm.visibleActivity == .editing)

        // No tool came back, so the island admits the agent is just thinking.
        f.clock.advance(by: .milliseconds(100))                        // t = 3.6
        #expect(f.vm.visibleActivity == .thinking)
        #expect(CodeCompactTrailing.slot(for: f.vm) == .activity(.thinking))
    }

    /// A prompt is the one thing worth taking the slot from a glyph that has just appeared.
    @Test func waitingInterruptsAGlyphThatHasJustAppeared() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.analyzing, tool: "Read"))
        f.clock.advance(by: .milliseconds(50))

        f.vm.handle(f.event(.waiting, detail: "Allow Bash to run rm -rf build?"))
        #expect(f.vm.visibleActivity == .waiting)
    }

    /// Once the session is gone the slot goes back to the usage ring immediately — a glyph
    /// lingering over an island that is no longer about a session would be a lie.
    @Test func theGlyphClearsWithTheSession() async {
        let f = makeFixture(results: [.claude: .success(usage(.claude, percent: 42))], defaults: defaults)
        await loadUsage(f)

        f.vm.handle(f.event(.creating, tool: "Edit"))
        #expect(f.vm.visibleActivity == .editing)

        f.vm.handle(f.event(.completed))
        #expect(f.vm.visibleActivity == .completed)

        f.clock.advance(by: CodeAgentViewModel.alertDuration)
        #expect(f.vm.visibleActivity == .idle)
        #expect(CodeCompactTrailing.slot(for: f.vm) == .ring(42))
    }

    // MARK: Caffeinate

    @Test func caffeinateFollowsTheSettingAndTheSessionCount() {
        let f = makeFixture(defaults: defaults)
        f.settings.caffeinate = true

        f.vm.handle(f.event(.thinking))
        #expect(f.vm.isCaffeinating)

        f.vm.handle(f.event(.completed))
        #expect(f.vm.isCaffeinating == false)              // no running session left
    }

    @Test func caffeinateStaysOffWhenTheSettingIsOff() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        #expect(f.vm.isCaffeinating == false)

        f.vm.toggleCaffeinate()
        #expect(f.settings.caffeinate)
        #expect(f.vm.isCaffeinating)

        f.vm.toggleCaffeinate()
        #expect(f.settings.caffeinate == false)
        #expect(f.vm.isCaffeinating == false)
    }

    // MARK: Agent selection

    @Test func selectAgentSwitchesTheDisplayedUsage() async {
        let f = makeFixture(
            results: [
                .claude: .success(usage(.claude, percent: 10)),
                .codex: .success(usage(.codex, percent: 80)),
            ],
            defaults: defaults
        )
        await loadUsage(f)

        #expect(f.vm.displayedUsage?.agent == .claude)
        #expect(f.vm.displayedUsage?.session?.percent == 10)

        f.vm.selectAgent(.codex)
        #expect(f.settings.currentAgent == .codex)
        #expect(f.vm.displayedAgent == .codex)
        #expect(f.vm.displayedUsage?.agent == .codex)
        #expect(f.vm.displayedUsage?.session?.percent == 80)
    }

    // MARK: Pace

    @Test func paceUsesTheWindowLengthAndRespectsTheSetting() async throws {
        let f = makeFixture(results: [.claude: .success(usage(.claude))], defaults: defaults)
        await loadUsage(f)

        // 5 h window with 1 h left → 80 % elapsed; 95 % used is well past the tolerance.
        let hot = UsageWindow(
            percent: 95,
            resetsAt: f.clock.currentDate.addingTimeInterval(3600),
            windowLength: 5 * 3600
        )
        #expect(f.vm.pace(for: hot) == .slowDown)

        let cool = UsageWindow(
            percent: 20,
            resetsAt: f.clock.currentDate.addingTimeInterval(3600),
            windowLength: 5 * 3600
        )
        #expect(f.vm.pace(for: cool) == .good)

        // The snapshot's weekly window reports no length. Judged over 7 d it is 14 % elapsed
        // against 20 % used — inside the tolerance. Judged over the 5 h session window it
        // would read as 0 % elapsed and wrongly say `.slowDown`.
        let weekly = try #require(f.vm.displayedUsage?.weekly)
        #expect(weekly.windowLength == nil)
        #expect(f.vm.pace(for: weekly) == .good)

        #expect(f.vm.pace(for: nil) == nil)

        f.settings.showPace = false
        #expect(f.vm.pace(for: hot) == nil)
    }

    // MARK: Ticking

    @Test func elapsedTicksOnlyBetweenStartAndStop() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        #expect(f.vm.elapsed == 0)

        f.clock.advance(by: .seconds(3))
        #expect(f.vm.elapsed == 0)                          // not ticking yet

        f.vm.startTicking()
        f.clock.advance(by: .seconds(4))
        #expect(f.vm.elapsed == 7)                          // 3 s before the start + 4 s after

        f.vm.stopTicking()
        f.clock.advance(by: .seconds(10))
        #expect(f.vm.elapsed == 7)
    }

    /// SwiftUI appears the incoming panel before it disappears the outgoing one, so the two
    /// overlap by a frame: the leaving panel's `stopTicking()` must not stop the clock the
    /// arriving one just started.
    @Test func aDisappearingPanelDoesNotStopTheClockANewOneStarted() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))

        f.vm.startTicking()          // idle panel appears
        f.vm.startTicking()          // activity panel appears over it
        f.vm.stopTicking()           // idle panel goes away
        f.clock.advance(by: .seconds(3))
        #expect(f.vm.elapsed == 3)

        f.vm.stopTicking()           // the last panel goes away
        f.clock.advance(by: .seconds(5))
        #expect(f.vm.elapsed == 3)
    }

    @Test func startTickingTwiceRunsOneClock() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        f.vm.startTicking()
        f.vm.startTicking()
        f.clock.advance(by: .seconds(4))
        // Two clocks would advance `elapsed` twice per second.
        #expect(f.vm.elapsed == 4)
    }

    @Test func tickingStopsWhenTheSessionEnds() {
        let f = makeFixture(defaults: defaults)
        f.vm.handle(f.event(.thinking))
        f.vm.startTicking()
        f.clock.advance(by: .seconds(2))
        #expect(f.vm.elapsed == 2)

        f.vm.handle(f.event(.completed))
        #expect(f.vm.elapsed == 0)
        f.clock.advance(by: .seconds(5))
        #expect(f.vm.elapsed == 0)
    }
}
