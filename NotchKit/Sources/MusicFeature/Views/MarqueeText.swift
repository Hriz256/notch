import SwiftUI

/// Scrolls text horizontally when it is wider than its container; static otherwise.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = .white
    var speed: Double = 30 // points per second
    /// The line box the marquee occupies. The expanded card's 13 pt title wants 18 pt; the
    /// track-change peek stacks an 11 pt title over a 9 pt artist inside the notch's height
    /// and asks for less.
    var height: CGFloat = 18

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var needsScroll: Bool { textWidth > containerWidth + 1 }
    /// One loop's travel: the title plus the gap to its copy, so the copy lands exactly where the
    /// title started and the jump back to 0 is invisible.
    private var distance: CGFloat { textWidth + Self.gap }
    private static let gap: CGFloat = 32
    private static let pause: TimeInterval = 1.2

    var body: some View {
        GeometryReader { geo in
            Group {
                if needsScroll {
                    // The keyframe animator owns the offset outright. Driving it with
                    // `withAnimation(.repeatForever)` instead layered a new loop on every
                    // restart — SwiftUI adds animations together and a repeat-forever one
                    // never finishes — so the stacked loops pushed the title out of the slot.
                    HStack(spacing: Self.gap) { label; label }
                        .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { row, x in
                            row.offset(x: x)
                        } keyframes: { _ in
                            KeyframeTrack {
                                LinearKeyframe(0, duration: Self.pause)
                                LinearKeyframe(-distance, duration: distance / speed)
                            }
                        }
                        .id(ScrollKey(text: text, distance: distance))
                } else {
                    label
                }
            }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
        }
        .frame(height: height)
        .clipped()
        .mask(edgeFade)
    }

    /// What a scroll loop runs for. A new title or a new distance gets a new identity, which
    /// starts one fresh loop from 0 instead of layering a second animation over the first.
    /// The text is part of the key because a new title can measure the same width, and the
    /// distance because on a track change the new width only lands after the next layout pass.
    private struct ScrollKey: Hashable {
        let text: String
        let distance: CGFloat
    }

    /// Fading both edges only earns its keep while the text scrolls under them. A title
    /// that fits is fully visible, so the same gradient would dim its first and last
    /// glyph for no reason — a plain opaque mask leaves it untouched and leading-aligned.
    /// The branch lives inside the one mask modifier rather than in `body`, so the mask adds
    /// no identity of its own to the scrolling row: its loop starts when the row appears and
    /// starts over only when `ScrollKey` changes.
    @ViewBuilder
    private var edgeFade: some View {
        if needsScroll {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                   .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        } else {
            Color.black
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            // `onGeometryChange` re-reports on every layout change, unlike an `onAppear`
            // inside a background reader: the `Text` keeps its identity across a track
            // change, so `onAppear` would fire once and freeze `textWidth` at the first
            // title's width.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
    }
}
