import Foundation
import Observation
import IslandCore
import CodeAgentShared

/// Live state of every agent session Notch knows about.
///
/// The tracker owns two timers per session, both re-armed on every event:
/// a finished session is kept for ``finishedRetention`` so the island can show its
/// completion alert, and a session that goes quiet for ``abandonTimeout`` is dropped
/// (agents have no "session closed" event we can rely on). No timer runs while
/// `sessions` is empty, which keeps the idle cost at zero.
@MainActor
@Observable
public final class SessionTracker {

    /// One agent conversation, as last reported by a hook.
    public struct Session: Equatable, Sendable, Identifiable {
        /// The agent's own session id (`session_id`, `thread-id`, `conversation_id`).
        public var id: String
        public var agent: Agent
        public var stage: Stage
        public var tool: String?
        public var detail: String?
        /// First event of the current run — reset when a finished session is revived.
        public var startedAt: Date
        public var lastEventAt: Date
        public var isFinished: Bool

        public init(
            id: String,
            agent: Agent,
            stage: Stage,
            tool: String? = nil,
            detail: String? = nil,
            startedAt: Date,
            lastEventAt: Date,
            isFinished: Bool
        ) {
            self.id = id
            self.agent = agent
            self.stage = stage
            self.tool = tool
            self.detail = detail
            self.startedAt = startedAt
            self.lastEventAt = lastEventAt
            self.isFinished = isFinished
        }
    }

    /// How long a completed or failed session stays visible for its alert.
    public static let finishedRetention: Duration = .seconds(60)
    /// How long a session may stay silent before it is presumed gone.
    public static let abandonTimeout: Duration = .seconds(1800)

    /// Keyed by ``key(agent:sessionID:)``, so two agents that both fall back to the
    /// `"unknown"` session id do not collide into a single entry.
    public private(set) var sessions: [String: Session] = [:]

    private let clock: any IslandClock
    private let now: @Sendable () -> Date
    @ObservationIgnored private var timers: [String: ScheduledToken] = [:]

    public init(clock: any IslandClock, now: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        self.now = now
    }

    /// Dictionary key for a session: agent-qualified so ids stay unique across agents.
    public static func key(agent: Agent, sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }

    /// The running session the island should show: the most recently active unfinished one.
    public var activeSession: Session? {
        newest(sessions.values.lazy.filter { !$0.isFinished })
    }

    /// Number of sessions currently running.
    public var activeCount: Int {
        sessions.values.reduce(into: 0) { $0 += $1.isFinished ? 0 : 1 }
    }

    /// The most recently finished session still inside the retention window.
    public var latestFinished: Session? {
        newest(sessions.values.lazy.filter(\.isFinished))
    }

    /// Folds one event into the session it belongs to, creating or reviving it as needed.
    ///
    /// Stage, tool and detail always mirror the latest event, so a `completed` event
    /// with no tool clears the tool shown by the previous one.
    public func handle(_ event: AgentEvent) {
        let key = Self.key(agent: event.agent, sessionID: event.sessionID)
        let finished = event.stage == .completed || event.stage == .failed

        var session = sessions[key] ?? Session(
            id: event.sessionID,
            agent: event.agent,
            stage: event.stage,
            startedAt: event.timestamp,
            lastEventAt: event.timestamp,
            isFinished: finished
        )
        if session.isFinished, !finished {
            // The user kept talking to a session we had already closed out.
            session.startedAt = event.timestamp
        }
        session.agent = event.agent
        session.stage = event.stage
        session.tool = event.tool
        session.detail = event.detail
        session.lastEventAt = event.timestamp
        session.isFinished = finished
        sessions[key] = session

        arm(key, finished: finished)
    }

    /// Drops every session and cancels the timers. Used when the feature is deactivated.
    public func reset() {
        for token in timers.values { token.cancel() }
        timers.removeAll()
        sessions.removeAll()
    }

    // MARK: - Timers

    private func arm(_ key: String, finished: Bool) {
        timers[key]?.cancel()
        let delay = finished ? Self.finishedRetention : Self.abandonTimeout
        let seconds = TimeInterval(delay.components.seconds)
        timers[key] = clock.schedule(after: delay) { [weak self] in
            guard let self else { return }
            // Belt and braces: a token that fires after its session saw a newer
            // event (or was revived into a longer window) must not drop it.
            guard let session = sessions[key] else { timers[key] = nil; return }
            guard now().timeIntervalSince(session.lastEventAt) >= seconds - 1 else { return }
            sessions[key] = nil
            timers[key] = nil
        }
    }

    private func newest(_ candidates: some Sequence<Session>) -> Session? {
        candidates.max { left, right in
            // Deterministic when two events share a timestamp.
            (left.lastEventAt, left.id) < (right.lastEventAt, right.id)
        }
    }
}
