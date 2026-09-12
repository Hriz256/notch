import AppKit
import os

/// Turns horizontal scrolling over the island into card-cycling swipes, using global +
/// local `.scrollWheel` monitors (neither needs Accessibility permission).
///
/// This type is only the plumbing: it installs the monitors, reads the pointer, and hands
/// the scalars to ``SwipeGestureRecognizer``, which owns the gesture grammar.
@MainActor
public final class ScrollSwipeMonitor {
    /// Horizontal travel, in points, that counts as a swipe.
    public static var threshold: CGFloat { SwipeGestureRecognizer.threshold }

    private let logger = Logger(subsystem: "app.notch", category: "surface.swipe")
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let rectProvider: () -> CGRect
    private let onSwipe: (IslandPresenter.CycleDirection) -> Void
    private var recognizer = SwipeGestureRecognizer()

    public init(
        rectProvider: @escaping () -> CGRect,
        onSwipe: @escaping (IslandPresenter.CycleDirection) -> Void
    ) {
        self.rectProvider = rectProvider
        self.onSwipe = onSwipe
    }

    public func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.dispatch(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.dispatch(event)
            return event
        }
    }

    /// Handles one monitored event, synchronously where it is safe to.
    ///
    /// Both monitor blocks run on the main thread: a local monitor is called from inside
    /// `-[NSApplication sendEvent:]`, and a global monitor is delivered through the same
    /// main run-loop event machinery (AppKit's header promises only that delivery is
    /// *asynchronous*, never a thread). That gap is why `Thread.isMainThread` is checked
    /// rather than assumed: `MainActor.assumeIsolated` traps when it is wrong, and this
    /// monitor sees every scroll event on the machine — far too hot a path to risk on an
    /// undocumented guarantee. The check costs a TLS read; the `Task` it avoids cost an
    /// allocation per event, almost always to discover the pointer was nowhere near the
    /// island.
    ///
    /// Only `Sendable` scalars are read off the event; `NSEvent` itself never escapes.
    private nonisolated func dispatch(_ event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let phase = event.phase.rawValue
        let momentum = event.momentumPhase.rawValue
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handle(deltaX: deltaX, deltaY: deltaY, phase: phase, momentum: momentum)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.handle(deltaX: deltaX, deltaY: deltaY, phase: phase, momentum: momentum)
            }
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        recognizer.reset()
    }

    // MARK: Private

    private func handle(deltaX: CGFloat, deltaY: CGFloat, phase: UInt, momentum: UInt) {
        let direction = recognizer.receive(
            deltaX: deltaX,
            deltaY: deltaY,
            phase: phase,
            momentum: momentum,
            // Autoclosure: not evaluated for the momentum events that make up most of the traffic.
            isOverIsland: rectProvider().contains(NSEvent.mouseLocation),
            now: Date()
        )
        // Diagnostic trail for gestures over the island: sideways scroll events with their
        // phase, momentum and outcome, so a swipe that "did not take" can be told apart
        // from one that never reached the recognizer. Debug level: dropped unless streamed.
        if abs(deltaX) >= 1 || abs(deltaY) >= 1, rectProvider().contains(NSEvent.mouseLocation) {
            logger.debug("scroll over island dx=\(deltaX, privacy: .public) dy=\(deltaY, privacy: .public) phase=\(phase, privacy: .public) momentum=\(momentum, privacy: .public) → \(direction.map { $0 == .next ? "next" : "previous" } ?? "-", privacy: .public)")
        }
        guard let direction else { return }
        // Info, not debug: this is one half of the swipe trail, and a `log show --info`
        // after the fact is the only way to tell "the gesture never fired" apart from
        // "it fired and the presenter ignored it". Debug lines are not retained.
        logger.info("island swipe \(direction == .next ? "next" : "previous", privacy: .public)")
        onSwipe(direction)
    }
}
