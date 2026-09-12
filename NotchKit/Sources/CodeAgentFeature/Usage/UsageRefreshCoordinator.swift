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
    /// Shortest gap between two sparkline scans, however many sessions finish in between.
    static let sparklineThrottle: TimeInterval = 60

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
    @ObservationIgnored private let sparkline: (any UsageSparkline)?
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let logger = UsageLog.logger("coordinator")

    @ObservationIgnored private var running = false
    @ObservationIgnored private var pollTokens: [Agent: ScheduledToken] = [:]
    @ObservationIgnored private var resetTokens: [Agent: [ScheduledToken]] = [:]
    @ObservationIgnored private var backoff: [Agent: TimeInterval] = [:]
    @ObservationIgnored private var inFlight: [Agent: Task<Void, Never>] = [:]
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var sparklineTask: Task<Void, Never>?
    /// The detached walk itself. Held separately because cancelling the task that *awaits* it
    /// does not propagate: an unstructured child keeps reading the whole tree.
    @ObservationIgnored private var sparklineScan: Task<[Double], Never>?
    @ObservationIgnored private var lastSparklineStart: Date?
    @ObservationIgnored private var latestSparkline: [Double]?

    public init(
        providers: [any UsageProvider],
        sparkline: (any UsageSparkline)?,
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
        sparklineTask?.cancel()
        sparklineTask = nil
        sparklineScan?.cancel()
        sparklineScan = nil
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
            // Whatever happens below, the slot has to be freed or the agent is never
            // polled again: `refresh` treats a non-nil entry as "already in flight".
            defer { self?.inFlight[agent] = nil }

            var result: Result<AgentUsage, UsageError>
            do throws(UsageError) {
                result = .success(try await provider.fetch())
            } catch {
                result = .failure(error)
            }

            guard let self, !Task.isCancelled else { return }

            result = self.withSparkline(result, for: agent)
            self.usage[agent] = result
            self.log(result, for: agent)
            self.scheduleNext(agent, after: result)
            // A failed Claude fetch means there is nothing to merge the totals into, and the
            // scan is the most expensive thing this coordinator does — so it does not run.
            if agent == .claude, case .success = result { self.refreshSparkline() }
        }
    }

    /// Asks for a fresh sparkline outside the poll cadence — a finished session is exactly
    /// when today's total changed and the user is most likely to look. Throttled, because a
    /// burst of sessions finishing together must not start a walk of the tree each time.
    public func sparklineNeedsRefresh() {
        guard running else { return }
        if let lastSparklineStart,
           now().timeIntervalSince(lastSparklineStart) < Self.sparklineThrottle { return }
        refreshSparkline()
    }

    // MARK: - Sparkline

    /// The 7-day scan walks every recent transcript on disk and can take a minute on a
    /// cold cache, so it never gates a publish: it is started only *after* the fetch
    /// result is stored, and the totals are merged into that snapshot when they arrive.
    ///
    /// Starting it afterwards rather than alongside the fetch is deliberate — a cold scan
    /// reads gigabytes, and running it first starves `claude --version` (which boots Node)
    /// badly enough to push the first publish out by more than a minute.
    ///
    /// One scan at a time — a poll that fires while the previous scan is still running
    /// reuses it rather than starting a second walk of the same tree.
    private func refreshSparkline() {
        guard let sparkline, sparklineTask == nil else { return }
        // Sampled here, on the main actor: `now` may be isolated to it in tests, and the
        // scan below runs off it.
        let startedAt = now()
        lastSparklineStart = startedAt

        let scan = Task.detached(priority: .utility) {
            await sparkline.dailyTotals(now: startedAt, days: 7)
        }
        sparklineScan = scan
        sparklineTask = Task { @MainActor [weak self] in
            let totals = await scan.value

            guard let self, !Task.isCancelled, !scan.isCancelled else { return }
            self.sparklineTask = nil
            self.sparklineScan = nil
            self.mergeSparkline(totals)
        }
    }

    /// Folds finished totals into the stored Claude snapshot, leaving every other field —
    /// and every other agent — untouched.
    private func mergeSparkline(_ totals: [Double]) {
        latestSparkline = totals
        guard case .success(var snapshot) = usage[.claude] else { return }
        snapshot.sparkline = totals
        usage[.claude] = .success(snapshot)
    }

    /// Carries the most recent totals into a freshly fetched Claude snapshot so a poll
    /// never blanks bars that are already on screen.
    private func withSparkline(
        _ result: Result<AgentUsage, UsageError>,
        for agent: Agent
    ) -> Result<AgentUsage, UsageError> {
        guard agent == .claude,
              let latestSparkline,
              case .success(var snapshot) = result
        else { return result }
        snapshot.sparkline = latestSparkline
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
                // A floor, not just a default: this endpoint answers some 429s with a
                // `Retry-After` of a few seconds, and honouring that walks straight back into
                // the sticky rate-limit bucket the User-Agent exists to stay out of.
                delay = min(max(retryAfter ?? Self.defaultBackoff, Self.defaultBackoff), Self.maximumBackoff)
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

    /// Awaits the pending sparkline scan so tests can assert on the merged snapshot.
    func settleSparkline() async {
        await sparklineTask?.value
    }
}
