import AppKit
import Testing
@testable import IslandCore

/// Feeds the recognizer the scalars a `.scrollWheel` event carries. Defaults describe the
/// common case: a trackpad gesture in flight, pointer over the island.
@MainActor
private func feed(
    _ recognizer: inout SwipeGestureRecognizer,
    deltaX: CGFloat = 0,
    deltaY: CGFloat = 0,
    phase: NSEvent.Phase = .changed,
    momentum: NSEvent.Phase = [],
    isOverIsland: Bool = true,
    now: Date = Date(timeIntervalSinceReferenceDate: 0)
) -> IslandPresenter.CycleDirection? {
    recognizer.receive(
        deltaX: deltaX,
        deltaY: deltaY,
        phase: phase.rawValue,
        momentum: momentum.rawValue,
        isOverIsland: isOverIsland,
        now: now
    )
}

/// The threshold is 4 pt: every literal below is written against that.
@MainActor
struct SwipeGestureRecognizerTests {
    private static let threshold = SwipeGestureRecognizer.threshold
    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func theThresholdIsAFlick() {
        #expect(Self.threshold == 4)
    }

    // MARK: Trackpad gestures

    @Test func accumulatedLeftSwipeFiresNextOnce() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, phase: .began) == nil)
        #expect(feed(&r, deltaX: -1.5) == nil)
        #expect(feed(&r, deltaX: -1.5) == nil)
        // Crosses the 4 pt threshold here.
        #expect(feed(&r, deltaX: -1.5) == .next)
        // A long swipe advances one card, not several.
        #expect(feed(&r, deltaX: -40) == nil)
        #expect(feed(&r, phase: .ended) == nil)
    }

    @Test func accumulatedRightSwipeFiresPrevious() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: Self.threshold) == .previous)
    }

    @Test func fingersDownFireNextAndFingersUpFirePrevious() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaY: 2) == nil)
        #expect(feed(&r, deltaY: 2) == .next)
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaY: -Self.threshold) == .previous)
    }

    @Test func theDominantAxisDecides() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        // More sideways than down: a horizontal swipe to the right.
        #expect(feed(&r, deltaX: 5, deltaY: 3) == .previous)
        _ = feed(&r, phase: .began)
        // More down than sideways: a vertical swipe down.
        #expect(feed(&r, deltaX: 3, deltaY: 5) == .next)
    }

    @Test func gestureBelowThresholdNeverFires() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -1, deltaY: 1) == nil)
        #expect(feed(&r, deltaX: -1, deltaY: 1) == nil)
        #expect(feed(&r, phase: .ended) == nil)
    }

    @Test func oppositeDeltasCancelWithinOneGesture() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -3) == nil)
        #expect(feed(&r, deltaX: 3) == nil)
        #expect(feed(&r, deltaX: 3) == nil)
        // Net +4 only now.
        #expect(feed(&r, deltaX: 1) == .previous)
    }

    @Test func beganResetsAPreviousGesture() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
        // A fresh gesture starts from zero, so a short travel is below threshold again.
        #expect(feed(&r, phase: .began) == nil)
        #expect(feed(&r, deltaX: -2) == nil)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -20) == .next)
    }

    @Test func endedResetsSoTheNextGestureFires() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        _ = feed(&r, deltaX: -20)
        #expect(feed(&r, phase: .ended) == nil)
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
    }

    @Test func cancelledResetsTheGesture() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -3) == nil)
        #expect(feed(&r, phase: .cancelled) == nil)
        // The 3 pt already travelled are gone.
        #expect(feed(&r, deltaX: -3) == nil)
    }

    @Test func momentumNeverFiresAGestureTwice() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
        _ = feed(&r, phase: .ended)
        // The momentum tail must not run through the rest of the stack.
        for _ in 0..<10 {
            #expect(feed(&r, deltaX: -60, phase: [], momentum: .changed) == nil)
        }
        #expect(feed(&r, deltaX: -60, phase: [], momentum: .ended) == nil)
    }

    /// A quick flick: a point or two under the fingers, the rest as momentum.
    @Test func aFlickFiresOnItsMomentumTail() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -1) == nil)
        #expect(feed(&r, deltaX: -1) == nil)
        #expect(feed(&r, phase: .ended) == nil)
        #expect(feed(&r, deltaX: -1, phase: [], momentum: .began) == nil)
        #expect(feed(&r, deltaX: -1, phase: [], momentum: .changed) == .next)
        // Once, and only once.
        #expect(feed(&r, deltaX: -30, phase: [], momentum: .changed) == nil)
        #expect(feed(&r, phase: [], momentum: .ended) == nil)
        // The tail's end closed the gesture: a stray momentum event fires nothing.
        #expect(feed(&r, deltaX: -60, phase: [], momentum: .changed) == nil)
    }

    @Test func momentumOfAGestureThatBeganOutsideNeverFires() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began, isOverIsland: false)
        #expect(feed(&r, deltaX: -3, isOverIsland: false) == nil)
        _ = feed(&r, phase: .ended, isOverIsland: false)
        #expect(feed(&r, deltaX: -60, phase: [], momentum: .changed) == nil)
    }

    @Test func aGestureThatBeginsOutsideTheIslandNeverFires() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began, isOverIsland: false)
        #expect(feed(&r, deltaX: -20, isOverIsland: false) == nil)
        // Even if the pointer drifts in mid-gesture: containment is latched at the start.
        #expect(feed(&r, deltaX: -20, isOverIsland: true) == nil)
    }

    /// The regression this latch exists for: the island rect is derived from whichever card
    /// is on screen, so a card arriving mid-swipe resizes it out from under a stationary
    /// pointer. Containment is decided once, at the start of the gesture.
    @Test func aGestureSurvivesTheIslandResizingUnderThePointer() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        #expect(feed(&r, deltaX: -2) == nil)
        #expect(feed(&r, deltaX: -2, isOverIsland: false) == .next)
    }

    /// Real trackpad deltas: `.began` carries nothing, then a few points at a time.
    @Test func typicalTrackpadDeltasFireExactlyOnce() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, phase: .began) == nil)
        #expect(feed(&r, deltaX: -1) == nil)
        #expect(feed(&r, deltaX: -2) == nil)
        #expect(feed(&r, deltaX: -3) == .next)
        for _ in 0..<5 {
            #expect(feed(&r, deltaX: -6, phase: [], momentum: .changed) == nil)
        }
    }

    @Test func mayBeginDoesNotFire() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, phase: .mayBegin) == nil)
        #expect(feed(&r, phase: .cancelled) == nil)
    }

    @Test func resetForgetsTheGestureInFlight() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, phase: .began)
        _ = feed(&r, deltaX: -3)
        r.reset()
        #expect(feed(&r, deltaX: -3) == nil)
    }

    // MARK: Phase-less mouse wheel

    @Test func wheelTickFiresPerTick() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaX: -Self.threshold, phase: [], now: Self.t0) == .next)
    }

    @Test func wheelTickBelowThresholdIsIgnored() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaX: -Self.threshold + 1, phase: [], now: Self.t0) == nil)
    }

    @Test func verticalWheelTicksPageToo() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaY: 20, phase: [], now: Self.t0) == .next)
        #expect(feed(&r, deltaY: -20, phase: [], now: Self.t0.addingTimeInterval(1)) == .previous)
    }

    @Test func wheelTicksAreRateLimited() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaX: -20, phase: [], now: Self.t0) == .next)
        #expect(feed(&r, deltaX: -20, phase: [], now: Self.t0.addingTimeInterval(0.1)) == nil)
        #expect(feed(&r, deltaX: -20, phase: [], now: Self.t0.addingTimeInterval(0.39)) == nil)
        #expect(feed(&r, deltaX: -20, phase: [], now: Self.t0.addingTimeInterval(0.4)) == .next)
    }

    @Test func wheelDirectionFollowsSign() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaX: 20, phase: [], now: Self.t0) == .previous)
        #expect(feed(&r, deltaX: -20, phase: [], now: Self.t0.addingTimeInterval(1)) == .next)
    }

    @Test func wheelTickOutsideTheIslandIsIgnored() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaX: -20, phase: [], isOverIsland: false, now: Self.t0) == nil)
    }

    @Test func containmentIsNotEvaluatedForMomentumEvents() {
        var r = SwipeGestureRecognizer()
        var lookups = 0
        _ = r.receive(
            deltaX: -60,
            phase: 0,
            momentum: NSEvent.Phase.changed.rawValue,
            isOverIsland: { lookups += 1; return true }(),
            now: Self.t0
        )
        #expect(lookups == 0)
    }
}
