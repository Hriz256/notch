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
            .onAppear { containerWidth = geo.size.width; restart() }
            .onChange(of: geo.size.width) { _, w in containerWidth = w; restart() }
            .onChange(of: text) { _, _ in restart() }
        }
        .frame(height: 18)
        .clipped()
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                   .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        )
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { g in Color.clear.onAppear { textWidth = g.size.width } })
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
