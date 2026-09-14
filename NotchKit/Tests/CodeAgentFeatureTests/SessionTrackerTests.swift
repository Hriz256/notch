import Testing
import Foundation
import IslandCore
import CodeAgentShared
@testable import CodeAgentFeature

/// Virtual clock: `advance` fires everything due, so the retention and abandon
/// timers can be exercised without sleeping.
@MainActor
final class ManualClock: IslandClock {
    private struct Entry { let due: Duration; let action: @MainActor () -> Void; let id: Int }
    private var entries: [Entry] = []
    private var nextID = 0
    private(set) var now: Duration = .zero
    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    var currentDate: Date { startDate.addingTimeInterval(now.timeIntervalValue) }
    var pendingCount: Int { entries.count }

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
    var timeIntervalValue: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

@MainActor
struct SessionTrackerTests {

    private func make() -> (SessionTracker, ManualClock) {
        let clock = ManualClock()
        let tracker = SessionTracker(clock: clock, now: { MainActor.assumeIsolated { clock.currentDate } })
        return (tracker, clock)
    }

    private func event(
        _ stage: Stage,
        session: String = "s1",
        agent: Agent = .claude,
        tool: String? = nil,
        detail: String? = nil,
        at offset: TimeInterval,
        clock: ManualClock
    ) -> AgentEvent {
        AgentEvent(
            agent: agent,
            sessionID: session,
            stage: stage,
            tool: tool,
            detail: detail,
            sourceApp: nil,
            timestamp: clock.startDate.addingTimeInterval(offset)
        )
    }

    @Test func createsSessionOnFirstEvent() throws {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, at: 0, clock: clock))

        let key = SessionTracker.key(agent: .claude, sessionID: "s1")
        let session = try #require(tracker.sessions[key])
        #expect(session.id == "s1")
        #expect(session.agent == .claude)
        #expect(session.stage == .thinking)
        #expect(session.startedAt == clock.startDate)
        #expect(session.lastEventAt == clock.startDate)
        #expect(session.isFinished == false)
        #expect(tracker.activeCount == 1)
    }

    @Test func updatesStageAndToolKeepingStartedAt() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, at: 0, clock: clock))
        clock.advance(by: .seconds(5))
        tracker.handle(event(.creating, tool: "Edit", detail: "Edit: a.swift", at: 5, clock: clock))

        let session = tracker.sessions[SessionTracker.key(agent: .claude, sessionID: "s1")]
        #expect(session?.stage == .creating)
        #expect(session?.tool == "Edit")
        #expect(session?.detail == "Edit: a.swift")
        #expect(session?.startedAt == clock.startDate)
        #expect(session?.lastEventAt == clock.startDate.addingTimeInterval(5))
        #expect(tracker.sessions.count == 1)
    }

    @Test func completedSessionIsRetainedThenRemoved() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, at: 0, clock: clock))
        tracker.handle(event(.completed, at: 0, clock: clock))

        let key = SessionTracker.key(agent: .claude, sessionID: "s1")
        #expect(tracker.sessions[key]?.isFinished == true)
        #expect(tracker.activeCount == 0)
        #expect(tracker.latestFinished?.id == "s1")

        clock.advance(by: .seconds(59))
        #expect(tracker.sessions[key] != nil)

        clock.advance(by: .seconds(2))
        #expect(tracker.sessions[key] == nil)
        #expect(tracker.latestFinished == nil)
    }

    /// A closed chat is gone at once: no retention window, no alert to keep it for.
    @Test func endedSessionIsDroppedAtOnce() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, at: 0, clock: clock))
        #expect(tracker.activeCount == 1)

        tracker.handle(event(.ended, at: 1, clock: clock))

        #expect(tracker.sessions.isEmpty)
        #expect(tracker.activeSession == nil)
        #expect(tracker.latestFinished == nil)
        #expect(clock.pendingCount == 0)
    }

    /// Claude Code sends SessionEnd long after Stop — when the user closes the terminal —
    /// by which time the finished session has been retired. That must not resurrect it.
    @Test func endedEventForAForgottenSessionCreatesNothing() {
        let (tracker, clock) = make()
        tracker.handle(event(.completed, at: 0, clock: clock))
        clock.advance(by: .seconds(61))
        #expect(tracker.sessions.isEmpty)

        tracker.handle(event(.ended, at: 61, clock: clock))

        #expect(tracker.sessions.isEmpty)
        #expect(tracker.latestFinished == nil)
        #expect(clock.pendingCount == 0)
    }

    @Test func failedSessionIsFinishedToo() {
        let (tracker, clock) = make()
        tracker.handle(event(.failed, at: 0, clock: clock))
        #expect(tracker.latestFinished?.stage == .failed)
        #expect(tracker.activeCount == 0)
    }

    @Test func unfinishedSessionIsAbandonedAfterSilence() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, at: 0, clock: clock))

        clock.advance(by: .seconds(1799))
        #expect(tracker.activeCount == 1)

        clock.advance(by: .seconds(2))
        #expect(tracker.sessions.isEmpty)
        #expect(tracker.activeSession == nil)
    }

    @Test func abandonTimerIsRearmedByEachEvent() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, at: 0, clock: clock))
        clock.advance(by: .seconds(1500))
        tracker.handle(event(.creating, tool: "Bash", at: 1500, clock: clock))

        clock.advance(by: .seconds(400))  // 1900 s after the first event, 400 after the last
        #expect(tracker.activeCount == 1)

        clock.advance(by: .seconds(1500))
        #expect(tracker.sessions.isEmpty)
    }

    @Test func activeSessionIsTheMostRecentUnfinishedOne() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, session: "old", at: 0, clock: clock))
        tracker.handle(event(.creating, session: "new", at: 10, clock: clock))
        tracker.handle(event(.completed, session: "newest", at: 20, clock: clock))

        #expect(tracker.activeSession?.id == "new")
        #expect(tracker.activeCount == 2)
        #expect(tracker.latestFinished?.id == "newest")
    }

    @Test func sessionsOfDifferentAgentsWithTheSameIDStaySeparate() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, session: "unknown", agent: .claude, at: 0, clock: clock))
        tracker.handle(event(.creating, session: "unknown", agent: .codex, at: 1, clock: clock))

        #expect(tracker.sessions.count == 2)
        #expect(tracker.activeSession?.agent == .codex)
    }

    @Test func eventAfterCompletionRevivesTheSession() {
        let (tracker, clock) = make()
        tracker.handle(event(.thinking, at: 0, clock: clock))
        tracker.handle(event(.completed, at: 1, clock: clock))

        clock.advance(by: .seconds(30))
        tracker.handle(event(.creating, tool: "Write", at: 30, clock: clock))

        let key = SessionTracker.key(agent: .claude, sessionID: "s1")
        #expect(tracker.sessions[key]?.isFinished == false)
        #expect(tracker.sessions[key]?.startedAt == clock.startDate.addingTimeInterval(30))
        #expect(tracker.activeCount == 1)
        #expect(tracker.latestFinished == nil)

        // The retention timer must have been cancelled, not merely re-armed.
        clock.advance(by: .seconds(60))
        #expect(tracker.sessions[key] != nil)
    }
}
