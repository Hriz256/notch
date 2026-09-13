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

/// The two curves the black shape itself moves on.
struct GeometrySpringTests {
    typealias Spring = TransitionChoreographer.Spring

    @Test func theShapeUsesTheRetunedSprings() {
        let c = TransitionChoreographer.standard
        #expect(c.geometry == Spring.grow.animation)
        #expect(c.collapseGeometry == Spring.collapse.animation)
        #expect(Spring.grow == .init(response: 0.38, damping: 0.82))
        #expect(Spring.collapse == .init(response: 0.30, damping: 0.92))
    }

    @Test func theGrowStaysInsideTheAppleWindow() {
        // Rule 1 of the yardstick: shape changes are springs, 0.35-0.5 s response,
        // 0.75-0.85 damping.
        #expect(Spring.grow.response >= 0.35 && Spring.grow.response <= 0.5)
        #expect(Spring.grow.damping >= 0.75 && Spring.grow.damping <= 0.85)
    }

    @Test func theCollapseIsTheSameGestureQuickerAndFlatter() {
        // Rule 3: same family, ~0.75x the response, damping >= 0.9 — and short of
        // critical, so it arrives rather than creeping.
        #expect(Spring.collapse.response < Spring.grow.response)
        #expect(Spring.collapse.response >= Spring.grow.response * 0.7)
        #expect(Spring.collapse.damping >= 0.9)
        #expect(Spring.collapse.damping < 1.0)
    }

    @Test func aMidExpandReversalGetsTheCollapseCurve() {
        // Interruptibility: the curve is chosen from where the island is heading, so a
        // collapse that starts while the grow is still in flight retargets on the
        // collapse spring (springs carry their velocity across).
        let c = TransitionChoreographer.standard
        let peek = IslandLayout(mode: .peek, size: CGSize(width: 312, height: 38), topRadius: 8, bottomRadius: 14)
        let expanded = IslandLayout(mode: .expanded, size: CGSize(width: 390, height: 200), topRadius: 12, bottomRadius: 24)
        #expect(c.geometryAnimation(from: expanded, to: peek) == c.collapseGeometry)
        #expect(c.geometryAnimation(from: peek, to: expanded) == c.geometry)
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
