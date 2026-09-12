import AppKit
import Foundation

/// The pure half of ``ScrollSwipeMonitor``: scroll-event scalars in, cycle directions out.
///
/// Nothing on the island scrolls, so any two-finger scroll over it is a request to turn
/// the page: both axes count (whichever the fingers travelled further along decides),
/// and the travel that counts is short — a flick of a few points. Fingers moving left
/// or down pull the next card in; right or up, the previous one.
///
/// Two event shapes arrive here. A trackpad gesture carries phases: the deltas are
/// accumulated from `.began` and fire once, so a single long swipe advances a single
/// card. The momentum tail that follows the fingers leaving the glass *continues* the
/// same gesture — a quick flick travels only a few points under the fingers and the rest
/// as momentum, and ignoring the tail made exactly those flicks feel dead — but it can
/// never make a gesture fire twice. A classic mouse wheel carries no phase at all, so
/// each qualifying tick fires directly, rate-limited so one flick of the wheel cannot run
/// through the whole stack.
///
/// It holds no AppKit state and reads no clock of its own, so the whole gesture grammar is
/// testable by feeding it deltas.
@MainActor
public struct SwipeGestureRecognizer {
    /// Travel along the dominant axis, in points, that counts as a swipe. Short on
    /// purpose: the user's trail showed flicks of 3–9 pt that read as dead at 12.
    public static let threshold: CGFloat = 4
    /// Minimum gap between two phase-less wheel ticks that both fire.
    public static let wheelInterval: TimeInterval = 0.4

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var didFireInGesture = false
    private var lastWheelFire: Date?
    /// Whether the gesture in flight started over the island. Latched on the first event of
    /// the gesture and reused for the rest of it — see ``receive(deltaX:phase:momentum:isOverIsland:now:)``.
    private var isGestureOverIsland: Bool?

    public init() {}

    /// Feeds one `.scrollWheel` event, already reduced to its `Sendable` scalars, and
    /// returns the direction to cycle if this event completed a swipe.
    ///
    /// - Parameters:
    ///   - deltaX: `NSEvent.scrollingDeltaX`, in points.
    ///   - deltaY: `NSEvent.scrollingDeltaY`, in points (natural scrolling: positive when
    ///     the fingers move down).
    ///   - rawPhase: `NSEvent.phase.rawValue`.
    ///   - rawMomentum: `NSEvent.momentumPhase.rawValue`. Non-zero means the fingers have
    ///     left the glass: the tail *continues* the gesture that was latched over the
    ///     island (a quick flick travels only a few points under the fingers), and its own
    ///     end closes that gesture for good. It is only discarded when no such gesture is
    ///     on record, or one has already fired.
    ///   - isOverIsland: whether the pointer sits inside the island. An `@autoclosure` so
    ///     the momentum test — by far the commonest rejection — runs before the caller
    ///     pays for a rect lookup on every scroll event on the machine.
    ///   - now: the caller's clock, for the wheel rate limit only.
    public mutating func receive(
        deltaX: CGFloat,
        deltaY: CGFloat = 0,
        phase rawPhase: UInt,
        momentum rawMomentum: UInt,
        isOverIsland: @autoclosure () -> Bool,
        now: Date
    ) -> IslandPresenter.CycleDirection? {
        if rawMomentum != 0 {
            // The momentum tail belongs to the gesture that just left the glass: it keeps
            // accumulating for a gesture that started over the island and has not fired,
            // and is dropped for everything else — a gesture that already fired, one that
            // began elsewhere, or a tail with no gesture on record. Containment is never
            // re-evaluated here; the latch decided it. The tail's own end closes the
            // gesture for good.
            let momentum = NSEvent.Phase(rawValue: rawMomentum)
            if momentum.contains(.ended) || momentum.contains(.cancelled) {
                reset()
                return nil
            }
            guard isGestureOverIsland == true, !didFireInGesture else { return nil }
            accumulatedX += deltaX
            accumulatedY += deltaY
            guard let direction = accumulatedDirection else { return nil }
            didFireInGesture = true
            return direction
        }

        let phase = NSEvent.Phase(rawValue: rawPhase)
        guard !phase.isEmpty else {
            // Phase-less wheel tick: no gesture to belong to, and each qualifying tick
            // fires on its own. The cheap scalar test comes first — most wheel events on
            // the machine are vertical scrolling that could never be a swipe, and the
            // pointer test behind the autoclosure is a rect lookup.
            guard let direction = Self.direction(x: deltaX, y: deltaY) else { return nil }
            guard isOverIsland() else { return nil }
            // Rate-limited, so one flick of the wheel cannot run through the whole stack.
            if let lastWheelFire, now.timeIntervalSince(lastWheelFire) < Self.wheelInterval { return nil }
            lastWheelFire = now
            return direction
        }

        if phase.contains(.began) { reset() }
        if phase.contains(.cancelled) {
            reset()
            return nil
        }
        // `.ended` keeps the gesture on record: its momentum tail may still carry the
        // travel that pushes it over the threshold. The next `.began` — or the tail's own
        // end — is what forgets it.
        if phase.contains(.ended) { return nil }
        // Containment is decided once per gesture, at its first event, and latched.
        //
        // Re-testing it per event used to cancel gestures that had every right to fire: the
        // island rect is derived from whatever card is on screen, so a card arriving
        // mid-swipe (a completion alert, a stage change) resizes it under a stationary
        // pointer and the gesture died silently. Latching also means the rect lookup — the
        // expensive half of this call — happens once instead of on every `.changed` event.
        let isInside: Bool
        if let isGestureOverIsland {
            isInside = isGestureOverIsland
        } else {
            isInside = isOverIsland()
            isGestureOverIsland = isInside
        }
        guard isInside else { return nil }
        accumulatedX += deltaX
        accumulatedY += deltaY
        guard !didFireInGesture, let direction = accumulatedDirection else { return nil }
        didFireInGesture = true
        return direction
    }

    /// The direction the travel so far asks for, once the dominant axis has covered the
    /// threshold; nil while it has not.
    private var accumulatedDirection: IslandPresenter.CycleDirection? {
        Self.direction(x: accumulatedX, y: accumulatedY)
    }

    /// Whichever axis the fingers travelled further along decides; below the threshold on
    /// both, nothing. Left or down → next; right or up → previous.
    private static func direction(x: CGFloat, y: CGFloat) -> IslandPresenter.CycleDirection? {
        if abs(x) >= abs(y) {
            guard abs(x) >= threshold else { return nil }
            return x < 0 ? .next : .previous
        }
        guard abs(y) >= threshold else { return nil }
        return y > 0 ? .next : .previous
    }

    /// Forgets the gesture in flight. The wheel rate limit is deliberately kept: it guards
    /// against a flick of the wheel, not against a particular gesture.
    public mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        didFireInGesture = false
        isGestureOverIsland = nil
    }

}
