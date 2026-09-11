import AppKit
import CodeAgentShared
import Foundation
import IslandCore

/// Owns every usage timer: the periodic poll, the 429 backoff, the one-shot refresh at
/// each window's reset, and the refresh after the machine wakes.
///
/// Scheduling goes through `IslandClock` so the cadence is testable without waiting.
@MainActor
@Observable
public final class UsageRefreshCoordinator {
    /// Poll cadence while at least one agent session is running.
    public static let activeInterval: Duration = .seconds(300)
    /// Poll cadence while everything is idle.
    public static let idleInterval: Duration = .seconds(900)
    /// First 429 backoff when the response carries no `Retry-After`.
    static let defaultBackoff: TimeInterval = 300
    /// Ceiling for the doubling backoff.
    static let maximumBackoff: TimeInterval = 3600
    /// Reset timers fire just after the boundary so the server has rolled the window over.
    static let resetSlack: TimeInterval = 5

    public private(set) var usage: [Agent: Result<AgentUsage, UsageError>] = [:]

    /// Drives the poll cadence; changing it re-arms the pending timers in place.
    public var isSessionActive: Bool = false {
        didSet {
            guard oldValue != isSessionActive else { return }
            reschedule()
        }
    }

    @ObservationIgnored private let providers: [Agent: any UsageProvider]
    @ObservationIgnored private let order: [Agent]
    @ObservationIgnored private let sparkline: ClaudeSparkline?
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let logger = UsageLog.logger("coordinator")

    @ObservationIgnored private var running = false
    @ObservationIgnored private var pollTokens: [Agent: ScheduledToken] = [:]
    @ObservationIgnored private var resetTokens: [Agent: [ScheduledToken]] = [:]
    @ObservationIgnored private var backoff: [Agent: TimeInterval] = [:]
    @ObservationIgnored private var inFlight: [Agent: Task<Void, Never>] = [:]
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    public init(
        providers: [any UsageProvider],
        sparkline: ClaudeSparkline?,
        clock: any IslandClock,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        var byAgent: [Agent: any UsageProvider] = [:]
        var order: [Agent] = []
        for provider in providers where byAgent[provider.agent] == nil {
            byAgent[provider.agent] = provider
            order.append(provider.agent)
        }
        self.providers = byAgent
        self.order = order
        self.sparkline = sparkline
        self.clock = clock
        self.now = now
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true

        // Timers do not fire while the machine sleeps, so state is re-derived on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }

        refreshNow()
    }

    public func stop() {
        running = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        for token in pollTokens.values { token.cancel() }
        pollTokens.removeAll()
        cancelResetTokens()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// Fetches every agent immediately, cancelling any pending poll.
    public func refreshNow() {
        for agent in order { refresh(agent) }
    }

    // MARK: - Fetching

    private func refresh(_ agent: Agent) {
        guard running, let provider = providers[agent], inFlight[agent] == nil else { return }
        pollTokens.removeValue(forKey: agent)?.cancel()

        inFlight[agent] = Task { @MainActor [weak self] in
            var result: Result<AgentUsage, UsageError>
            do throws(UsageError) {
                result = .success(try await provider.fetch())
            } catch {
                result = .failure(error)
            }

            guard let self else { return }
            result = await self.merged(result, for: agent)
            guard !Task.isCancelled else { return }

            self.usage[agent] = result
            self.inFlight[agent] = nil
            self.log(result, for: agent)
            self.scheduleNext(agent, after: result)
        }
    }

    /// Claude's bars and its 7-day sparkline are one snapshot in the UI, so the scan is
    /// folded into the fetch result rather than published separately.
    private func merged(
        _ result: Result<AgentUsage, UsageError>,
        for agent: Agent
    ) async -> Result<AgentUsage, UsageError> {
        guard agent == .claude, let sparkline, case .success(var snapshot) = result else { return result }
        snapshot.sparkline = await sparkline.dailyTotals(now: now())
        return .success(snapshot)
    }

    /// One line per settled fetch, so a failing agent can be diagnosed from the log alone.
    ///
    /// Only the two percentages are ever logged: token counts, plan names and the
    /// credentials behind them stay out of the system log.
    private func log(_ result: Result<AgentUsage, UsageError>, for agent: Agent) {
        let name = agent.rawValue
        switch result {
        case .success(let snapshot):
            let session = Self.percentText(snapshot.session?.percent)
            let weekly = Self.percentText(snapshot.weekly?.percent)
            logger.info("\(name, privacy: .public) usage: session \(session, privacy: .public), weekly \(weekly, privacy: .public)")
        case .failure(let error):
            logger.info("\(name, privacy: .public) usage unavailable: \(Self.describe(error), privacy: .public)")
        }
    }

    private static func percentText(_ percent: Double?) -> String {
        guard let percent else { return "n/a" }
        return "\(Int(percent.rounded()))%"
    }

    private static func describe(_ error: UsageError) -> String {
        switch error {
        case .notSignedIn: "not signed in"
        case .rateLimited(let retryAfter): "rate limited (retry after \(retryAfter.map { "\(Int($0))s" } ?? "unspecified"))"
        case .network(let reason): "network: \(reason)"
        case .unavailable(let reason): "unavailable: \(reason)"
        }
    }

    // MARK: - Scheduling

    private func scheduleNext(_ agent: Agent, after result: Result<AgentUsage, UsageError>) {
        guard running else { return }
        cancelResetTokens(for: agent)

        if case .failure(.rateLimited(let retryAfter)) = result {
            let delay: TimeInterval
            if let previous = backoff[agent] {
                delay = min(previous * 2, Self.maximumBackoff)
            } else {
                delay = min(retryAfter ?? Self.defaultBackoff, Self.maximumBackoff)
            }
            backoff[agent] = delay
            logger.debug("\(agent.rawValue, privacy: .public) rate limited, retrying in \(delay)s")
            schedulePoll(agent, after: .seconds(delay))
            return
        }

        backoff[agent] = nil
        schedulePoll(agent, after: pollInterval)
        if case .success(let snapshot) = result { scheduleResets(agent, snapshot) }
    }

    private func schedulePoll(_ agent: Agent, after delay: Duration) {
        pollTokens.removeValue(forKey: agent)?.cancel()
        pollTokens[agent] = clock.schedule(after: delay) { [weak self] in
            self?.refresh(agent)
        }
    }

    /// One extra refresh per window, right after it rolls over, so the bar snaps to its
    /// new value instead of staying stale for up to a whole poll interval.
    private func scheduleResets(_ agent: Agent, _ snapshot: AgentUsage) {
        let current = now()
        let tokens = [snapshot.session, snapshot.weekly]
            .compactMap(\.self)
            .compactMap(\.resetsAt)
            .map { $0.timeIntervalSince(current) + Self.resetSlack }
            .filter { $0 > 0 }
            .map { delay in
                clock.schedule(after: .seconds(delay)) { [weak self] in self?.refresh(agent) }
            }
        if !tokens.isEmpty { resetTokens[agent] = tokens }
    }

    private var pollInterval: Duration {
        isSessionActive ? Self.activeInterval : Self.idleInterval
    }

    /// Re-arms pending polls at the new cadence. Agents that are backing off after a 429
    /// keep their backoff — activity must not shorten a rate-limit penalty.
    private func reschedule() {
        guard running else { return }
        for agent in order where backoff[agent] == nil && pollTokens[agent] != nil {
            schedulePoll(agent, after: pollInterval)
        }
    }

    private func cancelResetTokens(for agent: Agent? = nil) {
        if let agent {
            resetTokens.removeValue(forKey: agent)?.forEach { $0.cancel() }
        } else {
            for tokens in resetTokens.values { tokens.forEach { $0.cancel() } }
            resetTokens.removeAll()
        }
    }

    // MARK: - Testing

    /// Awaits every in-flight fetch so tests can assert on settled state.
    func settle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }
}
