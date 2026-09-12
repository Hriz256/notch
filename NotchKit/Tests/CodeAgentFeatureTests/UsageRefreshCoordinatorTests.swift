import CodeAgentShared
import Foundation
import IslandCore
import Testing
@testable import CodeAgentFeature

// MARK: - Doubles

/// Local to this suite: `SessionTrackerTests` owns a same-named clock of its own.
@MainActor
final class UsageManualClock: IslandClock {
    private struct Entry {
        let due: Duration
        let action: @MainActor () -> Void
        let id: Int
    }

    private var entries: [Entry] = []
    private var nextID = 0
    private(set) var now: Duration = .zero

    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    var currentDate: Date { startDate.addingTimeInterval(now.seconds) }
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
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// Serialized fetch script + call counter. An actor rather than a lock so the fake is
/// `Sendable` without an unchecked promise.
private actor FetchRecorder {
    private var scripted: [Result<AgentUsage, UsageError>]
    private let fallback: Result<AgentUsage, UsageError>
    private(set) var calls = 0

    init(_ scripted: [Result<AgentUsage, UsageError>], fallback: Result<AgentUsage, UsageError>) {
        self.scripted = scripted
        self.fallback = fallback
    }

    func next() -> Result<AgentUsage, UsageError> {
        calls += 1
        return scripted.isEmpty ? fallback : scripted.removeFirst()
    }
}

private struct FakeProvider: UsageProvider {
    let agent: Agent
    let recorder: FetchRecorder

    func fetch() async throws(UsageError) -> AgentUsage {
        switch await recorder.next() {
        case .success(let usage): return usage
        case .failure(let error): throw error
        }
    }
}

/// A sparkline scan that parks until the test releases it, standing in for the minute-long
/// cold scan of `~/.claude/projects`.
private actor GatedSparkline: UsageSparkline {
    private let totals: [Double]
    private var waiter: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var calls = 0

    init(totals: [Double]) {
        self.totals = totals
    }

    func dailyTotals(now: Date, days: Int) async -> [Double] {
        calls += 1
        if !isReleased {
            await withCheckedContinuation { waiter = $0 }
        }
        return totals
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
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
        weekly: nil,
        sparkline: [],
        fetchedAt: fetchedAt,
        planLabel: nil
    )
}

// MARK: - Tests

@MainActor
struct UsageRefreshCoordinatorTests {
    private func make(
        agent: Agent = .codex,
        scripted: [Result<AgentUsage, UsageError>] = [],
        fallback: Result<AgentUsage, UsageError>? = nil
    ) -> (UsageRefreshCoordinator, FetchRecorder, UsageManualClock) {
        let clock = UsageManualClock()
        let recorder = FetchRecorder(scripted, fallback: fallback ?? .success(usage(agent)))
        let coordinator = UsageRefreshCoordinator(
            providers: [FakeProvider(agent: agent, recorder: recorder)],
            sparkline: nil,
            clock: clock,
            now: { MainActor.assumeIsolated { clock.currentDate } }
        )
        return (coordinator, recorder, clock)
    }

    @Test func startFetchesImmediately() async {
        let (coordinator, recorder, _) = make()
        coordinator.start()
        await coordinator.settle()

        #expect(await recorder.calls == 1)
        #expect(coordinator.usage[.codex] != nil)
    }

    @Test func storesResultPerAgent() async {
        let clock = UsageManualClock()
        let claude = FetchRecorder([], fallback: .success(usage(.claude, percent: 42)))
        let cursor = FetchRecorder([], fallback: .failure(.unavailable("Sign in to Cursor")))
        let coordinator = UsageRefreshCoordinator(
            providers: [
                FakeProvider(agent: .claude, recorder: claude),
                FakeProvider(agent: .cursor, recorder: cursor),
            ],
            sparkline: nil,
            clock: clock,
            now: { MainActor.assumeIsolated { clock.currentDate } }
        )

        coordinator.start()
        await coordinator.settle()

        guard case .success(let snapshot) = coordinator.usage[.claude] else {
            Issue.record("expected a Claude snapshot")
            return
        }
        #expect(snapshot.session?.percent == 42)
        #expect(coordinator.usage[.cursor] == .failure(.unavailable("Sign in to Cursor")))
    }

    private func makeClaude(
        sparkline: GatedSparkline,
        percent: Double = 42
    ) -> (UsageRefreshCoordinator, FetchRecorder, UsageManualClock) {
        let clock = UsageManualClock()
        let recorder = FetchRecorder([], fallback: .success(usage(.claude, percent: percent)))
        let coordinator = UsageRefreshCoordinator(
            providers: [FakeProvider(agent: .claude, recorder: recorder)],
            sparkline: sparkline,
            clock: clock,
            now: { MainActor.assumeIsolated { clock.currentDate } }
        )
        return (coordinator, recorder, clock)
    }

    @Test func claudeResultIsPublishedBeforeTheSparklineResolves() async {
        let sparkline = GatedSparkline(totals: [1, 2, 3, 4, 5, 6, 7])
        let (coordinator, _, _) = makeClaude(sparkline: sparkline)

        coordinator.start()
        await coordinator.settle()

        // The scan is still parked, yet the API result is already on screen.
        guard case .success(let pending) = coordinator.usage[.claude] else {
            Issue.record("expected the Claude snapshot before the sparkline resolved")
            return
        }
        #expect(pending.session?.percent == 42)
        #expect(pending.sparkline.isEmpty)

        await sparkline.release()
        await coordinator.settleSparkline()

        guard case .success(let merged) = coordinator.usage[.claude] else {
            Issue.record("expected the Claude snapshot after the sparkline resolved")
            return
        }
        #expect(merged.sparkline == [1, 2, 3, 4, 5, 6, 7])
        #expect(merged.session?.percent == 42)
    }

    @Test func onlyOneSparklineScanRunsAtATime() async {
        let sparkline = GatedSparkline(totals: [1, 1, 1, 1, 1, 1, 1])
        let (coordinator, recorder, _) = makeClaude(sparkline: sparkline)

        coordinator.start()
        await coordinator.settle()
        coordinator.refreshNow()
        await coordinator.settle()

        #expect(await recorder.calls == 2)
        #expect(await sparkline.calls == 1)

        await sparkline.release()
        await coordinator.settleSparkline()
        coordinator.stop()
    }

    /// A finished session is when today's total changed, so the panel should not wait out
    /// the poll interval — but a burst of sessions ending together must not start a walk of
    /// `~/.claude/projects` each time.
    @Test func finishedSessionsRescanTheSparklineAtMostOncePerMinute() async {
        let sparkline = GatedSparkline(totals: [3, 3, 3, 3, 3, 3, 3])
        let (coordinator, _, clock) = makeClaude(sparkline: sparkline)

        coordinator.start()
        await coordinator.settle()
        await sparkline.release()
        await coordinator.settleSparkline()
        #expect(await sparkline.calls == 1)

        // Inside the throttle window: the fetch's own scan still counts.
        clock.advance(by: .seconds(30))
        coordinator.sparklineNeedsRefresh()
        coordinator.sparklineNeedsRefresh()
        await coordinator.settleSparkline()
        #expect(await sparkline.calls == 1)

        clock.advance(by: .seconds(31))
        coordinator.sparklineNeedsRefresh()
        await coordinator.settleSparkline()
        #expect(await sparkline.calls == 2)

        coordinator.stop()
    }

    /// Nothing to merge totals into, and the scan is the single most expensive thing here.
    @Test func aFailedClaudeFetchDoesNotStartAScan() async {
        let clock = UsageManualClock()
        let sparkline = GatedSparkline(totals: [1, 1, 1, 1, 1, 1, 1])
        let recorder = FetchRecorder([], fallback: .failure(.notSignedIn))
        let coordinator = UsageRefreshCoordinator(
            providers: [FakeProvider(agent: .claude, recorder: recorder)],
            sparkline: sparkline,
            clock: clock,
            now: { MainActor.assumeIsolated { clock.currentDate } }
        )

        coordinator.start()
        await coordinator.settle()

        #expect(await sparkline.calls == 0)
        coordinator.stop()
    }

    @Test func aLaterPollKeepsTheSparklineAlreadyOnScreen() async {
        let sparkline = GatedSparkline(totals: [9, 9, 9, 9, 9, 9, 9])
        let (coordinator, _, clock) = makeClaude(sparkline: sparkline)

        coordinator.start()
        await coordinator.settle()
        await sparkline.release()
        await coordinator.settleSparkline()

        clock.advance(by: .seconds(900))
        await coordinator.settle()

        guard case .success(let snapshot) = coordinator.usage[.claude] else {
            Issue.record("expected a Claude snapshot after the poll")
            return
        }
        #expect(snapshot.sparkline == [9, 9, 9, 9, 9, 9, 9])
        await coordinator.settleSparkline()
        coordinator.stop()
    }

    @Test func idleCadenceIsFifteenMinutes() async {
        let (coordinator, recorder, clock) = make()
        coordinator.start()
        await coordinator.settle()

        clock.advance(by: .seconds(899))
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 2)
    }

    @Test func activeCadenceIsFiveMinutes() async {
        let (coordinator, recorder, clock) = make()
        coordinator.isSessionActive = true
        coordinator.start()
        await coordinator.settle()

        clock.advance(by: .seconds(299))
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 2)
    }

    @Test func becomingActiveRearmsThePendingPoll() async {
        let (coordinator, recorder, clock) = make()
        coordinator.start()
        await coordinator.settle()

        coordinator.isSessionActive = true
        clock.advance(by: .seconds(300))
        await coordinator.settle()
        #expect(await recorder.calls == 2)
    }

    @Test func rateLimitUsesRetryAfterThenDoubles() async {
        let (coordinator, recorder, clock) = make(
            scripted: [
                .failure(.rateLimited(retryAfter: 600)),
                .failure(.rateLimited(retryAfter: 600)),
            ]
        )
        coordinator.start()
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(599))
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 2)

        // Second 429 doubles 600 → 1200 rather than re-reading Retry-After.
        clock.advance(by: .seconds(1199))
        await coordinator.settle()
        #expect(await recorder.calls == 2)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 3)
    }

    /// Five minutes is a floor, not just a default: this endpoint answers some 429s with a
    /// `Retry-After` of seconds, and obeying that walks back into the sticky bucket.
    @Test func aShortRetryAfterIsFlooredAtFiveMinutes() async {
        let (coordinator, recorder, clock) = make(
            scripted: [.failure(.rateLimited(retryAfter: 20))]
        )
        coordinator.start()
        await coordinator.settle()

        clock.advance(by: .seconds(299))
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 2)
    }

    @Test func rateLimitWithoutRetryAfterFallsBackToFiveMinutes() async {
        let (coordinator, recorder, clock) = make(
            scripted: [.failure(.rateLimited(retryAfter: nil))]
        )
        coordinator.start()
        await coordinator.settle()

        clock.advance(by: .seconds(299))
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 2)
    }

    @Test func resetBoundaryFiresFiveSecondsAfterTheWindowRolls() async {
        let clock = UsageManualClock()
        let resetsAt = clock.startDate.addingTimeInterval(100)
        let recorder = FetchRecorder(
            [.success(usage(.codex, resetsAt: resetsAt))],
            fallback: .success(usage(.codex))
        )
        let coordinator = UsageRefreshCoordinator(
            providers: [FakeProvider(agent: .codex, recorder: recorder)],
            sparkline: nil,
            clock: clock,
            now: { MainActor.assumeIsolated { clock.currentDate } }
        )

        coordinator.start()
        await coordinator.settle()

        clock.advance(by: .seconds(104))
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 2)
    }

    @Test func refreshNowFetchesWithoutWaitingForTheTimer() async {
        let (coordinator, recorder, _) = make()
        coordinator.start()
        await coordinator.settle()

        coordinator.refreshNow()
        await coordinator.settle()
        #expect(await recorder.calls == 2)
    }

    @Test func stopCancelsEveryTimer() async {
        let clock = UsageManualClock()
        let resetsAt = clock.startDate.addingTimeInterval(100)
        let recorder = FetchRecorder(
            [.success(usage(.codex, resetsAt: resetsAt))],
            fallback: .success(usage(.codex))
        )
        let coordinator = UsageRefreshCoordinator(
            providers: [FakeProvider(agent: .codex, recorder: recorder)],
            sparkline: nil,
            clock: clock,
            now: { MainActor.assumeIsolated { clock.currentDate } }
        )

        coordinator.start()
        await coordinator.settle()
        #expect(clock.pendingCount == 2)  // poll + one reset boundary

        coordinator.stop()
        #expect(clock.pendingCount == 0)

        clock.advance(by: .seconds(3600))
        await coordinator.settle()
        #expect(await recorder.calls == 1)
    }
}
