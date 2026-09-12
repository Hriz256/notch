import CodeAgentShared
import Foundation
import Testing
@testable import CodeAgentFeature

/// The two rules that keep the island readable while agents work faster than an eye:
/// which session it is about (``CodeAgentViewModel/chooseDisplayedSession(current:sessions:now:)``)
/// and which glyph it draws (``ActivityDwell``). Both are pure, so both are tested here
/// against a hand-written timeline rather than through a rendered island.
@Suite("Activity smoothing")
@MainActor
struct ActivitySmoothingTests {

    // MARK: - Helpers

    /// `t(1.5)` is a second and a half into the timeline.
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ seconds: TimeInterval) -> Date { Self.epoch.addingTimeInterval(seconds) }

    private func session(
        _ id: String,
        agent: Agent = .claude,
        stage: Stage = .thinking,
        lastEventAt: TimeInterval,
        isFinished: Bool = false
    ) -> SessionTracker.Session {
        SessionTracker.Session(
            id: id,
            agent: agent,
            stage: stage,
            startedAt: Self.epoch,
            lastEventAt: t(lastEventAt),
            isFinished: isFinished
        )
    }

    private func table(_ sessions: SessionTracker.Session...) -> [String: SessionTracker.Session] {
        Dictionary(
            uniqueKeysWithValues: sessions.map {
                (SessionTracker.key(agent: $0.agent, sessionID: $0.id), $0)
            }
        )
    }

    // MARK: - A. The sticky displayed session

    @Test("With nothing displayed the island picks the session that moved last")
    func picksTheNewestWhenNothingIsDisplayed() {
        let chosen = CodeAgentViewModel.chooseDisplayedSession(
            current: nil,
            sessions: table(session("a", lastEventAt: 1), session("b", lastEventAt: 2)),
            now: t(2)
        )
        #expect(chosen?.id == "b")
    }

    /// The bug this rule exists for: two Claude Code windows interleaving hooks made the
    /// island flip between them several times a second.
    @Test("A busier neighbour never takes the island on its own")
    func staysOnTheDisplayedSessionWhileBothKeepWorking() {
        var displayed = session("a", lastEventAt: 0)
        var now: TimeInterval = 0

        // `b` fires twice as often as `a`, for a couple of seconds.
        for step in 1...12 {
            now = Double(step) * 0.2
            let a = session("a", lastEventAt: step % 2 == 0 ? now : now - 0.2)
            let b = session("b", lastEventAt: now)
            let chosen = CodeAgentViewModel.chooseDisplayedSession(
                current: displayed,
                sessions: table(a, b),
                now: t(now)
            )
            #expect(chosen?.id == "a")
            if let chosen { displayed = chosen }
        }
    }

    @Test("A displayed session that goes quiet hands over — but only after five seconds")
    func handsOverAfterFiveSecondsOfQuiet() {
        let quiet = session("a", lastEventAt: 0)

        // Four seconds in, `a` still owns the island even though `b` is the busy one.
        #expect(
            CodeAgentViewModel.chooseDisplayedSession(
                current: quiet,
                sessions: table(quiet, session("b", lastEventAt: 4)),
                now: t(4)
            )?.id == "a"
        )
        #expect(
            CodeAgentViewModel.chooseDisplayedSession(
                current: quiet,
                sessions: table(quiet, session("b", lastEventAt: 5)),
                now: t(5)
            )?.id == "b"
        )
    }

    /// Quiet on its own is not a handover: with nobody else working there is nothing to
    /// hand over *to*, and blanking the island would lose the session the user is watching.
    @Test("A quiet session keeps the island when the others are quiet too")
    func quietWithNoBusyNeighbourKeepsTheIsland() {
        let a = session("a", lastEventAt: 0)
        let b = session("b", lastEventAt: 1)
        #expect(
            CodeAgentViewModel.chooseDisplayedSession(current: a, sessions: table(a, b), now: t(30))?.id == "a"
        )
    }

    @Test("The island moves on when the session it is about finishes or is dropped")
    func finishedOrDroppedSessionReleasesTheIsland() {
        let running = session("a", lastEventAt: 0)
        let finished = session("a", stage: .completed, lastEventAt: 1, isFinished: true)
        let other = session("b", lastEventAt: 2)

        #expect(
            CodeAgentViewModel.chooseDisplayedSession(
                current: running,
                sessions: table(finished, other),
                now: t(2)
            )?.id == "b"
        )
        // The tracker dropped it (abandon timeout) — same outcome.
        #expect(
            CodeAgentViewModel.chooseDisplayedSession(
                current: running,
                sessions: table(other),
                now: t(2)
            )?.id == "b"
        )
        // And with nothing else running the island has no session at all.
        #expect(
            CodeAgentViewModel.chooseDisplayedSession(
                current: running,
                sessions: table(finished),
                now: t(2)
            ) == nil
        )
    }

    /// Two agents can both fall back to the same session id, so the rule has to compare the
    /// agent as well or it would mistake one for the other.
    @Test("Sessions are told apart by agent as well as id")
    func sameIdOnTwoAgentsAreTwoSessions() {
        let claude = session("unknown", agent: .claude, lastEventAt: 0)
        let codex = session("unknown", agent: .codex, lastEventAt: 6)
        let chosen = CodeAgentViewModel.chooseDisplayedSession(
            current: claude,
            sessions: table(claude, codex),
            now: t(6)
        )
        #expect(chosen?.agent == .codex)
    }

    // MARK: - B. Glyph dwell

    /// The timeline from the spec, event by event: a 100 ms `Read`, an `Edit` right behind
    /// it, and then the tool ending for good.
    @Test("A tool glyph owns the slot for 1.5 s, and lingers 2 s after the tool ends")
    func dwellTimeline() {
        var dwell = ActivityDwell()

        // t=0 — PreToolUse(Read). Nothing to protect yet, so the magnifier lands at once
        // and there is nothing pending.
        var due = dwell.update(target: .reading, now: t(0))
        #expect(dwell.visible == .reading)
        #expect(due == nil)

        // t=0.1 — PostToolUse. The read took 100 ms; without the linger the glyph would
        // have been on screen for a single frame.
        due = dwell.update(target: .thinking, now: t(0.1))
        #expect(dwell.visible == .reading)
        #expect(due == t(2.1))              // 0.1 + the 2 s linger

        // t=0.2 — PreToolUse(Edit). A different tool glyph, so it waits its turn.
        due = dwell.update(target: .editing, now: t(0.2))
        #expect(dwell.visible == .reading)
        #expect(due == t(1.5))

        // Right up to the deadline the magnifier is still the one on screen.
        _ = dwell.update(target: .editing, now: t(1.4))
        #expect(dwell.visible == .reading)

        // t=1.5 — the magnifier has had its time; the pencil takes over.
        due = dwell.update(target: .editing, now: t(1.5))
        #expect(dwell.visible == .editing)
        #expect(due == nil)

        // t=1.6 — PostToolUse. The pencil lingers two seconds waiting for the next tool.
        due = dwell.update(target: .thinking, now: t(1.6))
        #expect(dwell.visible == .editing)
        #expect(due == t(3.6))

        _ = dwell.update(target: .thinking, now: t(3.5))
        #expect(dwell.visible == .editing)

        // t=3.6 — no tool came; the agent is plainly just thinking.
        due = dwell.update(target: .thinking, now: t(3.6))
        #expect(dwell.visible == .thinking)
        #expect(due == nil)
    }

    /// A refresh arriving during the linger must not push the deadline out, or a session
    /// that keeps re-rendering would never reach the dots.
    @Test("Repeated thinking targets do not extend the linger")
    func lingerIsMeasuredFromTheFirstThinkingTarget() {
        var dwell = ActivityDwell()
        _ = dwell.update(target: .running, now: t(0))
        _ = dwell.update(target: .thinking, now: t(1))
        for step in 1...5 {
            let due = dwell.update(target: .thinking, now: t(1 + Double(step) * 0.3))
            #expect(due == t(3))            // 1 + the 2 s linger, unmoved
        }
        _ = dwell.update(target: .thinking, now: t(3))
        #expect(dwell.visible == .thinking)
    }

    /// The kinds that want the user are the ones worth interrupting a glyph for.
    @Test("Waiting, done, failed and idle jump the queue")
    func attentionKindsAreNeverHeldBack() {
        for interrupt: ActivityKind in [.waiting, .completed, .failed, .idle] {
            var dwell = ActivityDwell()
            _ = dwell.update(target: .reading, now: t(0))
            let due = dwell.update(target: interrupt, now: t(0.05))
            #expect(dwell.visible == interrupt)
            #expect(due == nil)
        }
    }

    /// The dwell only holds a *tool* glyph. Coming out of the dots — or off a fresh island
    /// — the next tool has to show up straight away, or the island would look asleep.
    @Test("The first tool after thinking appears at once")
    func thinkingDoesNotHoldTheNextToolBack() {
        var dwell = ActivityDwell()
        _ = dwell.update(target: .thinking, now: t(0))
        #expect(dwell.visible == .thinking)

        let due = dwell.update(target: .running, now: t(0.1))
        #expect(dwell.visible == .running)
        #expect(due == nil)
    }

    // MARK: - C. The thinking glyph

    @Test("Thinking is the one kind drawn without an SF symbol")
    func thinkingHasAGlyphOfItsOwn() {
        #expect(ActivityKind.thinking.symbol == nil)
        // …but it is still drawn: only the idle island leaves the slot empty.
        #expect(ActivityKind.thinking.drawsGlyph)
        #expect(!ActivityKind.idle.drawsGlyph)
        for kind: ActivityKind in [.reading, .editing, .running, .waiting, .completed, .failed] {
            #expect(kind.drawsGlyph)
        }
    }

    @Test("Only a tool call can hold the slot")
    func toolKinds() {
        #expect(ActivityKind.reading.isTool)
        #expect(ActivityKind.editing.isTool)
        #expect(ActivityKind.running.isTool)
        for kind: ActivityKind in [.thinking, .waiting, .completed, .failed, .idle] {
            #expect(!kind.isTool)
        }
    }

    /// Three dots, each up and back down inside its own third of the loop, one after the
    /// next — a wave rather than three dots blinking together.
    @Test("The dots rise in sequence and come back to rest")
    func thinkingDotsWave() {
        #expect(ThinkingDots.count == 3)
        #expect(ThinkingDots.diameter == 3)
        #expect(ThinkingDots.spacing == 3)
        #expect(ThinkingDots.rise == 2)
        #expect(ThinkingDots.period == 0.9)
        #expect(ThinkingDots.stagger == 0.15)

        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        // The first dot peaks an sixth of the way in — half of its third of the loop.
        #expect(abs(ThinkingDots.lift(epoch.addingTimeInterval(0.15), index: 0) - 2) < 0.0001)
        // …and the second is exactly one stagger behind it.
        #expect(abs(ThinkingDots.lift(epoch.addingTimeInterval(0.30), index: 1) - 2) < 0.0001)
        #expect(abs(ThinkingDots.lift(epoch.addingTimeInterval(0.45), index: 2) - 2) < 0.0001)

        // Each dot is on the ground at the start of its loop and for the rest of it.
        for index in 0..<ThinkingDots.count {
            let start = Double(index) * ThinkingDots.stagger
            #expect(abs(ThinkingDots.lift(epoch.addingTimeInterval(start), index: index)) < 0.0001)
            #expect(ThinkingDots.lift(epoch.addingTimeInterval(start + 0.4), index: index) == 0)
            #expect(ThinkingDots.lift(epoch.addingTimeInterval(start + 0.89), index: index) == 0)
        }

        // Never taller than the box claims for it.
        for hundredths in 0..<90 {
            let lift = ThinkingDots.lift(epoch.addingTimeInterval(Double(hundredths) / 100), index: 0)
            #expect(lift >= 0 && lift <= ThinkingDots.rise + 0.0001)
        }
    }
}
