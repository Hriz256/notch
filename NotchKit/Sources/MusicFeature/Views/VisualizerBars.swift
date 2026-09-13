import SwiftUI

/// The bars' geometry and timing, as pure functions so the drawing has no arithmetic in it
/// and the numbers can be tested without rendering.
///
/// Every bar is *drawn* at ``fullHeight`` and scaled down; nothing here returns a frame.
/// See ``VisualizerBars`` for why.
enum VisualizerMetrics {
    static let fullHeight: CGFloat = 14
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2
    /// The dot a paused bar rests as, as drawn before: a 3 pt square with a 1 pt radius.
    static let restingHeight: CGFloat = 3
    /// Each bar's tall phase, as a fraction of ``fullHeight``. The short phase is the value
    /// two places along, which is what keeps the four from pumping in unison.
    static let heights: [CGFloat] = [0.55, 1.0, 0.7, 0.85]

    static var barCount: Int { heights.count }

    /// The vertical scale bar `index` stands at. 1 is the full 14 pt.
    static func scale(bar index: Int, isPlaying: Bool, phase: Bool) -> CGFloat {
        guard isPlaying else { return restingHeight / fullHeight }
        return phase ? heights[index] : heights[(index + 2) % barCount]
    }

    /// Half-cycle for bar `index` while playing. Staggered, which is what stops four bars
    /// on one curve from reading as a metronome.
    static func period(bar index: Int) -> Double { 0.35 + Double(index) * 0.07 }

    /// How long a bar takes to drop to its resting dot when playback stops.
    static let settleDuration: Double = 0.2
}

/// Four bars that bounce while playing and rest as centered dots when paused.
/// Purely decorative.
///
/// The animated property is a **transform**, not a frame (audit A9): each bar is drawn once
/// at its full height and squashed by `scaleEffect(y:)`. Animating `.frame(height:)` instead
/// invalidates this subtree's layout on every displayed frame, for as long as music plays —
/// and the music peek is the island's resting state, so that was the app's steady-state cost
/// rather than a transient one. SwiftUI still drives the scale per frame; what it no longer
/// does is re-run layout to get there. No extra timer either way.
///
/// The bars occupy the same rectangles they did: the scale is the old height over 14, which
/// `VisualizerMetricsTests` pins to measured values. One thing genuinely changed — the 1 pt
/// corner radius is squashed along with the bar, so the paused dot's corners are ~0.21 pt
/// instead of 1 pt and read a little sharper. A `Capsule()` or a radius scaled back up does
/// not recover it (both are clamped by the 3 pt width), and animating the radius would put
/// the per-frame shape rebuild back, so it stands as a deliberate, noted regression.
struct VisualizerBars: View {
    let isPlaying: Bool
    var color: Color = .white
    @State private var phase = false

    /// Both inputs the bar scale depends on, so `.animation(_:value:)` re-evaluates
    /// whenever either changes.
    private struct AnimationKey: Equatable {
        let isPlaying: Bool
        let phase: Bool
    }

    var body: some View {
        // Centered so every bar grows symmetrically about the vertical midline: while
        // playing they expand up and down from the middle, and the resting dots land
        // exactly in the centre of the 14 pt frame instead of sitting on its floor. The
        // scale's anchor is `.center` for the same reason.
        HStack(alignment: .center, spacing: VisualizerMetrics.spacing) {
            ForEach(0..<VisualizerMetrics.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: VisualizerMetrics.barWidth, height: VisualizerMetrics.fullHeight)
                    .scaleEffect(y: VisualizerMetrics.scale(bar: i, isPlaying: isPlaying, phase: phase),
                                 anchor: .center)
                    // `.animation(_:value:)` only installs an animation when the keyed
                    // value changes, so the key is `[isPlaying, phase]`, not `phase`
                    // alone: the instant `isPlaying` flips the modifier is re-evaluated
                    // and the `repeatForever` is replaced by a single `.easeOut` down to
                    // the resting scale. Nothing repeating survives on a paused island,
                    // and resuming installs a fresh `repeatForever`.
                    .animation(isPlaying ? .easeInOut(duration: VisualizerMetrics.period(bar: i))
                                                .repeatForever(autoreverses: true)
                                         : .easeOut(duration: VisualizerMetrics.settleDuration),
                               value: AnimationKey(isPlaying: isPlaying, phase: phase))
            }
        }
        .frame(height: VisualizerMetrics.fullHeight, alignment: .center)
        .onAppear { if isPlaying { phase = true } }
        // Clear `phase` unanimated first so a resumed run always starts its repeating
        // animation from the same known state rather than from a half-finished cycle.
        .onChange(of: isPlaying) { _, playing in
            withAnimation(nil) { phase = false }
            if playing { phase = true }
        }
    }
}
