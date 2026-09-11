import SwiftUI

/// Four bars that bounce while playing and rest low when paused. Purely decorative.
struct VisualizerBars: View {
    let isPlaying: Bool
    var color: Color = .white
    @State private var phase = false

    private let heights: [CGFloat] = [0.55, 1.0, 0.7, 0.85]

    /// Both inputs the bar height depends on, so `.animation(_:value:)` re-evaluates
    /// whenever either changes.
    private struct AnimationKey: Equatable {
        let isPlaying: Bool
        let phase: Bool
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(heights.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3, height: isPlaying ? (phase ? 14 * heights[i] : 14 * heights[(i + 2) % 4]) : 3)
                    // `.animation(_:value:)` only installs an animation when the keyed
                    // value changes, so the key is `[isPlaying, phase]`, not `phase`
                    // alone: the instant `isPlaying` flips the modifier is re-evaluated
                    // and the `repeatForever` is replaced by a single `.easeOut` down to
                    // the resting height. Nothing repeating survives on a paused island,
                    // and resuming installs a fresh `repeatForever`.
                    .animation(isPlaying ? .easeInOut(duration: 0.35 + Double(i) * 0.07).repeatForever(autoreverses: true)
                                         : .easeOut(duration: 0.2),
                               value: AnimationKey(isPlaying: isPlaying, phase: phase))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .onAppear { if isPlaying { phase = true } }
        // Clear `phase` unanimated first so a resumed run always starts its repeating
        // animation from the same known state rather than from a half-finished cycle.
        .onChange(of: isPlaying) { _, playing in
            withAnimation(nil) { phase = false }
            if playing { phase = true }
        }
    }
}
