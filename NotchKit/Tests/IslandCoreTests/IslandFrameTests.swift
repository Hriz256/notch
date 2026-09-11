import Testing
import SwiftUI
@testable import IslandCore

struct IslandFrameTests {
    let notch = CGSize(width: 200, height: 38)

    @Test func clampRaisesAnUndershootToTheNotch() {
        // What an overshooting spring hands the modifier a few frames before it settles.
        let clamped = IslandFrame.clamped(size: CGSize(width: 194, height: 36.5), minimum: notch)
        #expect(clamped == notch)
    }

    @Test func clampLeavesSizesAboveTheFloorAlone() {
        let size = CGSize(width: 312, height: 200)
        #expect(IslandFrame.clamped(size: size, minimum: notch) == size)
    }

    @Test func clampIsPerAxis() {
        let clamped = IslandFrame.clamped(size: CGSize(width: 180, height: 200), minimum: notch)
        #expect(clamped == CGSize(width: 200, height: 200))
    }

    @Test func animatableDataRoundTripsSizeAndFlare() {
        var frame = IslandFrame(size: CGSize(width: 200, height: 38), flare: 6, minimum: notch)
        frame.animatableData = AnimatablePair(AnimatablePair(312, 200), 12)
        #expect(frame.size == CGSize(width: 312, height: 200))
        #expect(frame.flare == 12)
        #expect(frame.animatableData == AnimatablePair(AnimatablePair(312, 200), 12))
    }
}

struct GeometryAnimationTests {
    private func layout(_ size: CGSize, mode: IslandLayout.Mode) -> IslandLayout {
        IslandLayout(mode: mode, size: size, topRadius: 8, bottomRadius: 14)
    }

    var collapsed: IslandLayout { layout(CGSize(width: 200, height: 38), mode: .collapsed) }
    var peek: IslandLayout { layout(CGSize(width: 312, height: 38), mode: .peek) }
    var expanded: IslandLayout { layout(CGSize(width: 390, height: 200), mode: .expanded) }

    @Test func shrinkingNeedsBothAxes() {
        #expect(expanded.shrinks(to: collapsed))
        #expect(peek.shrinks(to: collapsed))
        #expect(!collapsed.shrinks(to: expanded))
        // Wider but shorter is not a collapse.
        #expect(!peek.shrinks(to: expanded))
    }

    @Test func collapseUsesTheCriticallyDampedCurve() {
        let c = TransitionChoreographer.standard
        #expect(c.geometryAnimation(from: expanded, to: collapsed) == c.collapseGeometry)
        #expect(c.geometryAnimation(from: peek, to: collapsed) == c.collapseGeometry)
    }

    @Test func expansionStaysBouncy() {
        let c = TransitionChoreographer.standard
        #expect(c.geometryAnimation(from: collapsed, to: peek) == c.geometry)
        #expect(c.geometryAnimation(from: peek, to: expanded) == c.geometry)
        #expect(c.geometryAnimation(from: nil, to: peek) == c.geometry)
    }

    @Test func reducedMotionUsesOneCurveInBothDirections() {
        let c = TransitionChoreographer.reducedMotion
        #expect(c.collapseGeometry == c.geometry)
    }
}
