import Testing
import SwiftUI
@testable import IslandCore

/// The island is one shape growing out of the notch, and its content belongs to that
/// shape. These tests pin the timing relationships that make it read that way; the curves
/// themselves are judged by eye.
struct ContentTimingTests {
    typealias Spring = TransitionChoreographer.Spring

    @Test func contentEntersOnASpringWithNoDelay() {
        let c = TransitionChoreographer.standard
        #expect(c.contentIn == Spring.contentIn.animation)
        // The 60 ms delay is what made the island an empty black box for four frames.
        #expect(c.contentIn != Spring.contentIn.animation.delay(0.06))
    }

    @Test func contentLeavesOnASpringThatOverlapsTheCollapse() {
        let c = TransitionChoreographer.standard
        #expect(c.contentOut == Spring.contentOut.animation)
        // Quicker than the shape — content should not lag it — but not so much quicker
        // that the panel finishes deflating empty. Half the collapse is the floor.
        #expect(Spring.contentOut.response < Spring.collapse.response)
        #expect(Spring.contentOut.response > Spring.collapse.response / 2)
    }

    @Test func contentIsQuickerThanTheShapeInBothDirections() {
        #expect(Spring.contentIn.response < Spring.grow.response)
        #expect(Spring.contentOut.response < Spring.contentIn.response)
    }

    @Test func bothContentCurvesAreSpringsSoAReversalRetargets() {
        // Ease curves restart from zero when a promote is reversed mid-flight; springs
        // retarget from their current value and velocity.
        let c = TransitionChoreographer.standard
        #expect(c.contentIn != .easeOut(duration: Spring.contentIn.response))
        #expect(c.contentOut != .easeIn(duration: Spring.contentOut.response))
    }

    @Test func reducedMotionHasNoDelayEither() {
        let c = TransitionChoreographer.reducedMotion
        #expect(c.contentIn == .easeInOut(duration: 0.2))
        #expect(c.contentOut == .easeInOut(duration: 0.15))
    }
}
