import Testing
import CoreGraphics
@testable import IslandCore

/// The page indicator is one bright dot that travels and grows, over a track of dim ones.
struct StackDotMetricsTests {
    @Test func theMarkerIsBiggerThanTheDotsItTravelsOver() {
        #expect(StackDotMetrics.activeSize > StackDotMetrics.size)
        #expect(StackDotMetrics.activeDiameter(isReduced: false) == 4)
        #expect(StackDotMetrics.size == 3)
    }

    @Test func theMarkerStaysConcentricWithTheDotItMarks() {
        for index in 0..<4 {
            let diameter = StackDotMetrics.activeDiameter(isReduced: false)
            let centre = StackDotMetrics.activeOffset(index: index, isReduced: false) + diameter / 2
            #expect(centre == StackDotMetrics.dotCentre(index: index))
        }
    }

    @Test func theMarkerTravelsOneDotPitchPerPage() {
        let first = StackDotMetrics.activeOffset(index: 0, isReduced: false)
        let second = StackDotMetrics.activeOffset(index: 1, isReduced: false)
        #expect(second - first == StackDotMetrics.stride)
        #expect(StackDotMetrics.stride == 8)
    }

    @Test func reduceMotionKeepsTheMarkerDotSizedAndStillConcentric() {
        #expect(StackDotMetrics.activeDiameter(isReduced: true) == StackDotMetrics.size)
        let offset = StackDotMetrics.activeOffset(index: 2, isReduced: true)
        #expect(offset + StackDotMetrics.size / 2 == StackDotMetrics.dotCentre(index: 2))
        // Sitting exactly on the dot it replaces: no half-point nudge.
        #expect(offset == CGFloat(2) * StackDotMetrics.stride)
    }

    @Test func theDotsRideTheirOwnSpring() {
        let c = TransitionChoreographer.standard
        #expect(c.stackDot == TransitionChoreographer.Spring.stackDot.animation)
        #expect(TransitionChoreographer.Spring.stackDot == .init(response: 0.3, damping: 0.8))
    }
}
