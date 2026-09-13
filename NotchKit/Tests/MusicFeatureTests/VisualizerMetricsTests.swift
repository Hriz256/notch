import Testing
import CoreGraphics
@testable import MusicFeature

/// The bars animate a `scaleEffect(y:)` on a bar drawn at full height, so these fractions are
/// what used to be a `.frame(height:)`. The point of the test is that the rectangles on screen
/// did not change when the property did, so the expected heights are **written out**, not
/// re-derived from the same constants the code uses — a test that multiplies `heights[i]` by
/// `fullHeight` on both sides proves only that multiplication is commutative.
///
/// The values are the ones the pre-transform code produced: 14 × [0.55, 1.0, 0.7, 0.85], and
/// a 3 pt dot at rest.
struct VisualizerMetricsTests {
    private func expectClose(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    /// Height in points bar `index` is drawn at, i.e. what the old `.frame(height:)` set.
    private func height(bar index: Int, isPlaying: Bool = true, phase: Bool = true) -> CGFloat {
        VisualizerMetrics.scale(bar: index, isPlaying: isPlaying, phase: phase) * VisualizerMetrics.fullHeight
    }

    @Test func playingBarsStandAtTheHeightsTheyUsedTo() {
        let expected: [CGFloat] = [7.7, 14.0, 9.8, 11.9]
        for i in 0..<VisualizerMetrics.barCount {
            #expect(expectClose(height(bar: i), expected[i], 1e-6))
        }
    }

    /// The short phase is the value two places along, which is what stops the four bars
    /// pumping in unison: [0.7, 0.85, 0.55, 1.0] × 14.
    @Test func theOffPhaseTakesTheHeightTwoPlacesAlong() {
        let expected: [CGFloat] = [9.8, 11.9, 7.7, 14.0]
        for i in 0..<VisualizerMetrics.barCount {
            #expect(expectClose(height(bar: i, phase: false), expected[i], 1e-6))
        }
    }

    @Test func pausedBarsRestAtAThreePointDotWhateverThePhase() {
        for phase in [true, false] {
            for i in 0..<VisualizerMetrics.barCount {
                #expect(expectClose(height(bar: i, isPlaying: false, phase: phase), 3.0, 1e-6))
            }
        }
    }

    @Test func theBarsAreDrawnThreePointsWideAtFourteenTall() {
        #expect(VisualizerMetrics.fullHeight == 14)
        #expect(VisualizerMetrics.barWidth == 3)
        #expect(VisualizerMetrics.barCount == 4)
    }

    /// No bar may be scaled past the height it is drawn at: a scale above 1 would draw
    /// outside the row's 14 pt frame and clip against the notch.
    @Test func noBarScalesAboveOne() {
        for phase in [true, false] {
            for i in 0..<VisualizerMetrics.barCount {
                let scale = VisualizerMetrics.scale(bar: i, isPlaying: true, phase: phase)
                #expect(scale > 0 && scale <= 1)
            }
        }
    }

    /// The stagger is the whole character of the motion; four bars on one period read as a
    /// metronome.
    @Test func periodsAreStaggeredAndAscending() {
        let periods = (0..<VisualizerMetrics.barCount).map { VisualizerMetrics.period(bar: $0) }
        #expect(zip(periods, [0.35, 0.42, 0.49, 0.56]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(zip(periods, periods.dropFirst()).allSatisfy { $0 < $1 })
    }
}
