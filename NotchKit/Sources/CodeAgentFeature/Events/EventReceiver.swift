import Foundation
import OSLog
import CodeAgentShared

/// Bridges the distributed notification posted by the `notch-hook` CLI into
/// normalized ``AgentEvent`` values on the main actor.
///
/// Every notification is delivered: a hook fires a handful of times per tool call
/// and the whole path is `JSONSerialization` + a dictionary lookup, so throttling
/// here would only add latency to the "waiting for you" alert. Rate limiting the
/// *UI* (spec §4: at most 10 updates/s) belongs to the view model, which is the
/// only thing that can coalesce two events into one presentation.
///
/// The observer is not removed in `deinit` (a non-isolated `deinit` may not touch
/// main-actor state): the owner calls ``stop()`` from `deactivate()`.
@MainActor
public final class EventReceiver {

    /// Name posted by `notch-hook`; must stay in sync with the CLI.
    public static let notificationName = Notification.Name("app.notch.agent.event")

    private let onEvent: @MainActor (AgentEvent) -> Void
    private let center = DistributedNotificationCenter.default()
    private let logger = Logger(subsystem: "app.notch", category: "code.events")
    private var observer: (any NSObjectProtocol)?
    /// Injection point for tests; production always uses the wall clock.
    var now: @Sendable () -> Date = { Date() }

    public init(onEvent: @escaping @MainActor (AgentEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// Starts observing. Calling it twice is a no-op.
    public func start() {
        guard observer == nil else { return }
        observer = center.addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Only `Sendable` strings cross the boundary; the queue is `.main`, so
            // the hop is an assertion rather than a scheduling decision.
            let agent = notification.userInfo?["agent"] as? String
            let payload = notification.userInfo?["payload"] as? String
            MainActor.assumeIsolated {
                self?.receive(agent: agent, payload: payload)
            }
        }
    }

    /// Stops observing. Safe to call when not started.
    public func stop() {
        guard let observer else { return }
        center.removeObserver(observer)
        self.observer = nil
    }

    /// Parses one notification body. Malformed input is dropped and logged at debug
    /// level; payload contents are never logged.
    func receive(agent rawAgent: String?, payload: String?) {
        guard let rawAgent, let agent = Agent(rawValue: rawAgent) else {
            logger.debug("dropping event: unknown agent")
            return
        }
        guard let payload, !payload.isEmpty else {
            logger.debug("dropping \(rawAgent, privacy: .public) event: empty payload")
            return
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let object = parsed as? [String: Any]
        else {
            logger.debug("dropping \(rawAgent, privacy: .public) event: payload is not a JSON object")
            return
        }
        // The event's name only — never its payload, which carries prompts and commands.
        var name = (object["hook_event_name"] ?? object["type"] ?? object["hook_event"]) as? String ?? "?"
        if let type = object["notification_type"] as? String { name += "/\(type)" }
        guard let event = StageMapper.map(agent: agent, payload: object, now: now()) else {
            logger.debug("ignoring \(rawAgent, privacy: .public) \(name, privacy: .public)")
            return
        }
        logger.debug("received \(rawAgent, privacy: .public) \(name, privacy: .public) → \(event.stage.rawValue, privacy: .public)")
        onEvent(event)
    }
}
