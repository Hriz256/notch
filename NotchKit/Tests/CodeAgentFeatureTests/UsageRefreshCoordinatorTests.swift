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
                .failure(.rateLimited(retryAfter: 120)),
                .failure(.rateLimited(retryAfter: 120)),
            ]
        )
        coordinator.start()
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(119))
        await coordinator.settle()
        #expect(await recorder.calls == 1)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 2)

        // Second 429 doubles 120 → 240 rather than re-reading Retry-After.
        clock.advance(by: .seconds(239))
        await coordinator.settle()
        #expect(await recorder.calls == 2)

        clock.advance(by: .seconds(1))
        await coordinator.settle()
        #expect(await recorder.calls == 3)
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
