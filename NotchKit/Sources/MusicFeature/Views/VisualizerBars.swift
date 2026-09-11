import SwiftUI

/// Four bars that bounce while playing and rest low when paused. Purely decorative.
struct VisualizerBars: View {
    let isPlaying: Bool
    var color: Color = .white
    @State private var phase = false

    private let heights: [CGFloat] = [0.55, 1.0, 0.7, 0.85]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(heights.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3, height: isPlaying ? (phase ? 14 * heights[i] : 14 * heights[(i + 2) % 4]) : 3)
                    .animation(isPlaying ? .easeInOut(duration: 0.35 + Double(i) * 0.07).repeatForever(autoreverses: true) : .easeOut(duration: 0.2), value: phase)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .onAppear { if isPlaying { phase = true } }
        .onChange(of: isPlaying) { _, playing in phase = playing }
    }
}
