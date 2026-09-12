import AppKit
import Testing
@testable import IslandCore

/// Feeds the recognizer the scalars a `.scrollWheel` event carries. Defaults describe the
/// common case: a trackpad gesture in flight, pointer over the island.
@MainActor
private func feed(
    _ recognizer: inout SwipeGestureRecognizer,
    deltaX: CGFloat,
    phase: NSEvent.Phase = .changed,
    momentum: NSEvent.Phase = [],
    isOverIsland: Bool = true,
    now: Date = Date(timeIntervalSinceReferenceDate: 0)
) -> IslandPresenter.CycleDirection? {
    recognizer.receive(
        deltaX: deltaX,
        phase: phase.rawValue,
        momentum: momentum.rawValue,
        isOverIsland: isOverIsland,
        now: now
    )
}

@MainActor
struct SwipeGestureRecognizerTests {
    private static let threshold = SwipeGestureRecognizer.threshold
    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: Trackpad gestures

    @Test func accumulatedLeftSwipeFiresNextOnce() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaX: 0, phase: .began) == nil)
        #expect(feed(&r, deltaX: -5) == nil)
        #expect(feed(&r, deltaX: -5) == nil)
        // Crosses the 12 pt threshold here.
        #expect(feed(&r, deltaX: -5) == .next)
        // A long swipe advances one card, not several.
        #expect(feed(&r, deltaX: -40) == nil)
        #expect(feed(&r, deltaX: 0, phase: .ended) == nil)
    }

    @Test func accumulatedRightSwipeFiresPrevious() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: Self.threshold) == .previous)
    }

    @Test func gestureBelowThresholdNeverFires() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: -4) == nil)
        #expect(feed(&r, deltaX: -4) == nil)
        #expect(feed(&r, deltaX: 0, phase: .ended) == nil)
    }

    @Test func oppositeDeltasCancelWithinOneGesture() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: -10) == nil)
        #expect(feed(&r, deltaX: 10) == nil)
        #expect(feed(&r, deltaX: 10) == nil)
        // Net +12 only now.
        #expect(feed(&r, deltaX: 2) == .previous)
    }

    @Test func beganResetsAPreviousGesture() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
        // A fresh gesture starts from zero, so a short travel is below threshold again.
        #expect(feed(&r, deltaX: 0, phase: .began) == nil)
        #expect(feed(&r, deltaX: -5) == nil)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
    }

    @Test func endedResetsSoTheNextGestureFires() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        _ = feed(&r, deltaX: -20)
        #expect(feed(&r, deltaX: 0, phase: .ended) == nil)
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
    }

    @Test func cancelledResetsTheGesture() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: -8) == nil)
        #expect(feed(&r, deltaX: 0, phase: .cancelled) == nil)
        // The 8 pt already travelled are gone.
        #expect(feed(&r, deltaX: -8) == nil)
    }

    @Test func momentumIsIgnoredEvenAboveThreshold() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: -Self.threshold) == .next)
        _ = feed(&r, deltaX: 0, phase: .ended)
        // The momentum tail must not run through the rest of the stack.
        for _ in 0..<10 {
            #expect(feed(&r, deltaX: -60, phase: [], momentum: .changed) == nil)
        }
        #expect(feed(&r, deltaX: -60, phase: [], momentum: .ended) == nil)
    }

    @Test func eventsOutsideTheIslandAreIgnoredAndCancelTheGesture() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        #expect(feed(&r, deltaX: -8) == nil)
        #expect(feed(&r, deltaX: -8, isOverIsland: false) == nil)
        // The pointer left: the travel so far is discarded.
        #expect(feed(&r, deltaX: -8) == nil)
    }

    @Test func mayBeginDoesNotFire() {
        var r = SwipeGestureRecognizer()
        #expect(feed(&r, deltaX: 0, phase: .mayBegin) == nil)
        #expect(feed(&r, deltaX: 0, phase: .cancelled) == nil)
    }

    @Test func resetForgetsTheGestureInFlight() {
        var r = SwipeGestureRecognizer()
        _ = feed(&r, deltaX: 0, phase: .began)
        _ = feed(&r, deltaX: -8)
        r.reset()
        #expect(feed(&r, deltaX: -8) == nil)
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
