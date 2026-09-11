import SwiftUI

/// Scrolls text horizontally when it is wider than its container; static otherwise.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = .white
    var speed: Double = 30 // points per second

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var needsScroll: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 32) {
                label
                if needsScroll { label }
            }
            .offset(x: needsScroll ? offset : 0)
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
            // The scroll loop depends on the two measured widths, so restart when either
            // lands rather than when `text` changes: on a track change the new width is
            // only known after the next layout pass.
            .onChange(of: containerWidth) { _, _ in restart() }
            .onChange(of: textWidth) { _, _ in restart() }
            // A new title that happens to measure the same width leaves `textWidth`
            // unchanged, so also restart here; the widths are still correct in that case.
            // Assigning `offset` outside an animation also cancels the previous loop
            // immediately so the old title's scroll does not linger under the new one.
            .onChange(of: text) { _, _ in offset = 0; restart() }
        }
        .frame(height: 18)
        .clipped()
        .mask(edgeFade)
    }

    /// Fading both edges only earns its keep while the text scrolls under them. A title
    /// that fits is fully visible, so the same gradient would dim its first and last
    /// glyph for no reason — a plain opaque mask leaves it untouched and leading-aligned.
    /// Keeping one mask modifier (rather than branching on `needsScroll` in `body`) keeps
    /// the marquee's view identity stable, so the running scroll animation survives the
    /// moment a longer title flips `needsScroll`.
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

    private func restart() {
        offset = 0
        guard needsScroll else { return }
        let distance = textWidth + 32
        withAnimation(.linear(duration: distance / speed).delay(1.2).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}
