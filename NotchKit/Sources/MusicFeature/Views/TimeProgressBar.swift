import SwiftUI
import NowPlayingShared

/// Elapsed / remaining labels around a thin seekable bar.
struct TimeProgressBar: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    var tint: Color = .white
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(TimeFormatting.mmss(fraction * duration))
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.25))
                    Capsule().fill(tint).frame(width: geo.size.width * fraction)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(1, max(0, v.location.x / geo.size.width)) }
                        .onEnded { v in
                            let f = min(1, max(0, v.location.x / geo.size.width))
                            dragFraction = nil
                            onSeek(f * duration)
                        }
                )
            }
            .frame(height: 12)
            Text("-" + TimeFormatting.mmss(max(0, duration - fraction * duration)))
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(tint.opacity(0.8))
    }
}
