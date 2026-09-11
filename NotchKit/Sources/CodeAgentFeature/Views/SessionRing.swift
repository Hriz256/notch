import SwiftUI

/// How much of the session rate-limit window is spent, as a ring.
///
/// This is the idle island's trailing badge: small enough to read at a glance from
/// the notch, and it animates rather than jumping when a usage poll lands.
struct SessionRing: View {
    /// 0…100. Values outside the range are clamped.
    let percent: Double
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    var tint: Color = CodePalette.salmon

    private var fraction: Double {
        min(1, max(0, percent / 100))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // `trim` starts at 3 o'clock; rotate so the arc grows clockwise from
                // the top, the way a clock face reads.
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: fraction)
        }
        // Inset by half the stroke so the ring's outer edge lands on the frame rather
        // than bleeding past it.
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .accessibilityLabel("\(Int(fraction * 100))% of session used")
    }
}
