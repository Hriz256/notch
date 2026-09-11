import Foundation

public struct ScheduledToken {
    private let onCancel: () -> Void
    public init(cancel: @escaping () -> Void) { onCancel = cancel }
    public func cancel() { onCancel() }
}

/// Abstraction over "run this on the main actor after a delay" so the presenter is testable.
@MainActor
public protocol IslandClock {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledToken
}

/// Production clock backed by structured concurrency.
@MainActor
public final class TaskClock: IslandClock {
    public init() {}
    public func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return ScheduledToken { task.cancel() }
    }
}
