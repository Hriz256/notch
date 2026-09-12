import AppKit
import os

/// Turns horizontal scrolling over the island into card-cycling swipes, using global +
/// local `.scrollWheel` monitors (neither needs Accessibility permission).
///
/// Two event shapes arrive here. A trackpad gesture carries phases: the deltas are
/// accumulated from `.began` and fire once, so a single long swipe advances a single
/// card; momentum deltas that follow the fingers leaving the glass are ignored outright.
/// A classic mouse wheel carries no phase at all, so each qualifying tick fires directly,
/// rate-limited so one flick of the wheel cannot run through the whole stack.
@MainActor
public final class ScrollSwipeMonitor {
    /// Horizontal travel, in points, that counts as a swipe.
    public static let threshold: CGFloat = 12
    private static let wheelInterval: TimeInterval = 0.4

    private let logger = Logger(subsystem: "app.notch", category: "surface.swipe")
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let rectProvider: () -> CGRect
    private let onSwipe: (IslandPresenter.CycleDirection) -> Void

    private var accumulatedX: CGFloat = 0
    private var didFireInGesture = false
    private var lastWheelFire: Date?

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

    /// Handles one monitored event synchronously.
    ///
    /// These blocks run on the main thread, so the isolation is an assertion rather than a
    /// scheduling decision — the same shape as `EventReceiver`. It matters because this
    /// monitor sees *every* scroll event on the system: hopping through a `Task` allocated
    /// one per event, the overwhelming majority of them for a pointer nowhere near the
    /// island. The containment test in ``handle(deltaX:phase:momentum:)`` runs first and
    /// costs nothing; it stays there because an event outside the island must also cancel a
    /// gesture that started inside it.
    ///
    /// Only `Sendable` scalars are read off the event; `NSEvent` itself never escapes.
    private nonisolated func dispatch(_ event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let phase = event.phase.rawValue
        let momentum = event.momentumPhase.rawValue
        MainActor.assumeIsolated {
            handle(deltaX: deltaX, phase: phase, momentum: momentum)
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        resetGesture()
    }

    // MARK: Private

    private func handle(deltaX: CGFloat, phase rawPhase: UInt, momentum rawMomentum: UInt) {
        // Momentum is the tail of a gesture that already fired; it must never fire again.
        guard rawMomentum == 0 else { return }
        let phase = NSEvent.Phase(rawValue: rawPhase)
        guard rectProvider().contains(NSEvent.mouseLocation) else {
            resetGesture()
            return
        }

        guard !phase.isEmpty else {
            // Phase-less wheel tick: fire per tick, rate-limited.
            guard abs(deltaX) >= Self.threshold else { return }
            let now = Date()
            if let lastWheelFire, now.timeIntervalSince(lastWheelFire) < Self.wheelInterval { return }
            self.lastWheelFire = now
            fire(deltaX)
            return
        }

        if phase.contains(.began) { resetGesture() }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            resetGesture()
            return
        }
        accumulatedX += deltaX
        guard !didFireInGesture, abs(accumulatedX) >= Self.threshold else { return }
        didFireInGesture = true
        fire(accumulatedX)
    }

    /// Natural direction: fingers moving left (negative delta) pull the next card in.
    private func fire(_ deltaX: CGFloat) {
        let direction: IslandPresenter.CycleDirection = deltaX < 0 ? .next : .previous
        logger.debug("island swipe \(deltaX < 0 ? "next" : "previous", privacy: .public)")
        onSwipe(direction)
    }

    private func resetGesture() {
        accumulatedX = 0
        didFireInGesture = false
    }
}
