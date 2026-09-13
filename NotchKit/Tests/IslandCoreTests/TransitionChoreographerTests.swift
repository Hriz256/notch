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

/// Content has to arrive the way the shape does: out of the notch, at the top.
struct ContentMotionTests {
    @Test func contentUnfoldsFromUnderTheNotch() {
        let motion = IslandContentMotion.unfold(isReduced: false)
        #expect(motion.scale == 0.96)
        // Negative: content starts above its resting place, i.e. under the hardware.
        #expect(motion.offset.height == -4)
        #expect(motion.offset.width == 0)
    }

    @Test func theBlurIsAGarnishNotASmear() {
        let motion = IslandContentMotion.unfold(isReduced: false)
        #expect(motion.blur == 2.5)
        // The audit's ceiling for 13 pt type; the old 6 pt was a smear.
        #expect(motion.blur <= 3)
    }

    @Test func theScaleStaysSubtleEnoughToReadAsOneShape() {
        // A deep scale reads as a picture being zoomed inside a box rather than as the
        // box unfolding.
        let motion = IslandContentMotion.unfold(isReduced: false)
        #expect(motion.scale >= 0.95)
        #expect(motion.scale < 1)
    }

    @Test func reduceMotionIsOpacityOnly() {
        #expect(IslandContentMotion.unfold(isReduced: true) == .still)
        #expect(IslandContentMotion.still.scale == 1)
        #expect(IslandContentMotion.still.offset == .zero)
        #expect(IslandContentMotion.still.blur == 0)
    }

    @Test func theReducedChoreographerIsTheOneThatReduces() {
        #expect(TransitionChoreographer.reducedMotion.isReduced)
        #expect(!TransitionChoreographer.standard.isReduced)
    }
}
