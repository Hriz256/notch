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

/// A page turn is neither a grow nor a collapse, and it has a direction.
struct PageChangeTests {
    typealias Spring = TransitionChoreographer.Spring

    private func layout(_ size: CGSize, mode: IslandLayout.Mode) -> IslandLayout {
        IslandLayout(mode: mode, size: size, topRadius: 12, bottomRadius: 24)
    }

    private var tall: IslandLayout { layout(CGSize(width: 380, height: 170), mode: .expanded) }
    private var short: IslandLayout { layout(CGSize(width: 380, height: 124), mode: .expanded) }
    private var peek: IslandLayout { layout(CGSize(width: 312, height: 38), mode: .peek) }
    private var collapsed: IslandLayout { layout(CGSize(width: 200, height: 38), mode: .collapsed) }

    @Test func bothDirectionsOfASwipeGetTheSameCurve() {
        // Code 380x170 -> stash 380x124 used to be judged a collapse, and the same swipe
        // back a grow: one gesture, two feels.
        let c = TransitionChoreographer.standard
        #expect(TransitionChoreographer.kind(from: tall, to: short, presentationChanged: true) == .pageChange)
        #expect(TransitionChoreographer.kind(from: short, to: tall, presentationChanged: true) == .pageChange)
        #expect(c.geometryAnimation(from: tall, to: short, presentationChanged: true) == c.pageChange)
        #expect(c.geometryAnimation(from: short, to: tall, presentationChanged: true) == c.pageChange)
        #expect(c.pageChange == Spring.pageChange.animation)
    }

    @Test func changingModeIsStillAGrowOrACollapse() {
        // Hovering a different card at the same moment is an expansion, not a page turn.
        #expect(TransitionChoreographer.kind(from: peek, to: tall, presentationChanged: true) == .grow)
        #expect(TransitionChoreographer.kind(from: tall, to: peek, presentationChanged: true) == .collapse)
        // And an island going away is a collapse however its card changed.
        #expect(TransitionChoreographer.kind(from: peek, to: collapsed, presentationChanged: true) == .collapse)
    }

    @Test func theSameCardResizingIsNotAPageTurn() {
        #expect(TransitionChoreographer.kind(from: tall, to: short, presentationChanged: false) == .collapse)
        #expect(TransitionChoreographer.kind(from: short, to: tall, presentationChanged: false) == .grow)
        #expect(TransitionChoreographer.kind(from: nil, to: tall, presentationChanged: true) == .grow)
    }

    @Test func thePageCurveSitsBetweenTheGrowAndTheCollapse() {
        #expect(Spring.pageChange.response < Spring.grow.response)
        #expect(Spring.pageChange.response > Spring.collapse.response)
    }

    @Test func contentSlidesAlongTheAxisOfTheGesture() {
        let inNext = IslandContentMotion.page(.next, inserting: true, isReduced: false)
        let outNext = IslandContentMotion.page(.next, inserting: false, isReduced: false)
        // Forward: the new card comes from the right, the old one leaves to the left.
        #expect(inNext.offset.width == 14)
        #expect(outNext.offset.width == -14)
        // Backward is the mirror image, exactly.
        #expect(IslandContentMotion.page(.previous, inserting: true, isReduced: false).offset.width == -14)
        #expect(IslandContentMotion.page(.previous, inserting: false, isReduced: false).offset.width == 14)
    }

    @Test func aPageTurnOnlyTranslates() {
        // No scale, no blur, no vertical move: content is not growing out of the notch,
        // it is sliding past the one already there.
        for direction in [IslandPresenter.CycleDirection.next, .previous] {
            for inserting in [true, false] {
                let motion = IslandContentMotion.page(direction, inserting: inserting, isReduced: false)
                #expect(motion.scale == 1)
                #expect(motion.blur == 0)
                #expect(motion.offset.height == 0)
            }
        }
    }

    @Test func theSlideStaysUnderTheIslandsEdge() {
        // Small enough to read as content moving inside the island rather than a panel
        // sliding in from outside it — the "separate shape" the owner rejected.
        #expect(IslandContentMotion.pageSlide <= 16)
    }

    @Test func reduceMotionSwipesWithoutMoving() {
        #expect(IslandContentMotion.page(.next, inserting: true, isReduced: true) == .still)
        #expect(IslandContentMotion.page(.previous, inserting: false, isReduced: true) == .still)
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
