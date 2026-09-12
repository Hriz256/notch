import AppKit
import Foundation

/// The pure half of ``ScrollSwipeMonitor``: scroll-event scalars in, cycle directions out.
///
/// Two event shapes arrive here. A trackpad gesture carries phases: the deltas are
/// accumulated from `.began` and fire once, so a single long swipe advances a single
/// card; momentum deltas that follow the fingers leaving the glass are ignored outright.
/// A classic mouse wheel carries no phase at all, so each qualifying tick fires directly,
/// rate-limited so one flick of the wheel cannot run through the whole stack.
///
/// It holds no AppKit state and reads no clock of its own, so the whole gesture grammar is
/// testable by feeding it deltas.
@MainActor
public struct SwipeGestureRecognizer {
    /// Horizontal travel, in points, that counts as a swipe.
    public static let threshold: CGFloat = 12
    /// Minimum gap between two phase-less wheel ticks that both fire.
    public static let wheelInterval: TimeInterval = 0.4

    private var accumulatedX: CGFloat = 0
    private var didFireInGesture = false
    private var lastWheelFire: Date?

    public init() {}

    /// Feeds one `.scrollWheel` event, already reduced to its `Sendable` scalars, and
    /// returns the direction to cycle if this event completed a swipe.
    ///
    /// - Parameters:
    ///   - deltaX: `NSEvent.scrollingDeltaX`, in points.
    ///   - rawPhase: `NSEvent.phase.rawValue`.
    ///   - rawMomentum: `NSEvent.momentumPhase.rawValue`; anything non-zero is discarded.
    ///   - isOverIsland: whether the pointer sits inside the island. An `@autoclosure` so
    ///     the momentum test — by far the commonest rejection — runs before the caller
    ///     pays for a rect lookup on every scroll event on the machine.
    ///   - now: the caller's clock, for the wheel rate limit only.
    public mutating func receive(
        deltaX: CGFloat,
        phase rawPhase: UInt,
        momentum rawMomentum: UInt,
        isOverIsland: @autoclosure () -> Bool,
        now: Date
    ) -> IslandPresenter.CycleDirection? {
        // Momentum is the tail of a gesture that already fired; it must never fire again.
        guard rawMomentum == 0 else { return nil }
        // An event outside the island also cancels a gesture that started inside it.
        guard isOverIsland() else {
            reset()
            return nil
        }

        let phase = NSEvent.Phase(rawValue: rawPhase)
        guard !phase.isEmpty else {
            // Phase-less wheel tick: fire per tick, rate-limited.
            guard abs(deltaX) >= Self.threshold else { return nil }
            if let lastWheelFire, now.timeIntervalSince(lastWheelFire) < Self.wheelInterval { return nil }
            lastWheelFire = now
            return Self.direction(of: deltaX)
        }

        if phase.contains(.began) { reset() }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            reset()
            return nil
        }
        accumulatedX += deltaX
        guard !didFireInGesture, abs(accumulatedX) >= Self.threshold else { return nil }
        didFireInGesture = true
        return Self.direction(of: accumulatedX)
    }

    /// Forgets the gesture in flight. The wheel rate limit is deliberately kept: it guards
    /// against a flick of the wheel, not against a particular gesture.
    public mutating func reset() {
        accumulatedX = 0
        didFireInGesture = false
    }

    /// Natural direction: fingers moving left (negative delta) pull the next card in.
    private static func direction(of deltaX: CGFloat) -> IslandPresenter.CycleDirection {
        deltaX < 0 ? .next : .previous
    }
}
