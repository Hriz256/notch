import Testing
import CoreGraphics
@testable import MusicFeature

/// The bars animate a `scaleEffect(y:)` on a bar drawn at full height, so these fractions are
/// what used to be a `.frame(height:)`. The point of the test is that the *pixels* did not
/// change when the property did: `scale × fullHeight` must equal the height the old code set.
struct VisualizerMetricsTests {
    private func expectClose(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func playingBarsScaleToTheHeightsTheyUsedToBeGiven() {
        for i in 0..<VisualizerMetrics.barCount {
            let tall = VisualizerMetrics.scale(bar: i, isPlaying: true, phase: true)
            #expect(expectClose(tall * VisualizerMetrics.fullHeight,
                                VisualizerMetrics.fullHeight * VisualizerMetrics.heights[i]))
        }
    }

    /// The short phase is the value two places along, which is what stops the four bars
    /// pumping in unison.
    @Test func theOffPhaseTakesTheHeightTwoPlacesAlong() {
        for i in 0..<VisualizerMetrics.barCount {
            let short = VisualizerMetrics.scale(bar: i, isPlaying: true, phase: false)
            #expect(short == VisualizerMetrics.heights[(i + 2) % VisualizerMetrics.barCount])
        }
        // ...and the pairing is a genuine swap, not the identity.
        #expect(VisualizerMetrics.scale(bar: 0, isPlaying: true, phase: false)
                != VisualizerMetrics.scale(bar: 0, isPlaying: true, phase: true))
    }

    @Test func pausedBarsRestAtTheDotHeightWhateverThePhase() {
        for phase in [true, false] {
            for i in 0..<VisualizerMetrics.barCount {
                let scale = VisualizerMetrics.scale(bar: i, isPlaying: false, phase: phase)
                #expect(expectClose(scale * VisualizerMetrics.fullHeight, VisualizerMetrics.restingHeight))
            }
        }
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
