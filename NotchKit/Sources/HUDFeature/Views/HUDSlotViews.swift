import HUDShared
import SwiftUI

/// The bar's geometry, kept out of the view so it can be tested (spec §2 "The bar").
public enum HUDBarLayout {
    public static let size = CGSize(width: 60, height: 4)
    /// How far the peek slot's content stays from the island's edge.
    public static let inset: CGFloat = 12

    public static func fillWidth(fraction: Double, total: CGFloat) -> CGFloat {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return total * CGFloat(clamped)
    }
}

/// Leading slot: the symbol and the label, hugging the island's left edge.
struct HUDLeadingView: View {
    let model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if let reading = model.reading {
                // The glyph morphs rather than swaps as the level crosses the thirds
                // (audit B3). The 14 pt box stays fixed either way: `speaker.wave.3.fill`
                // is wider than `speaker.slash.fill`, and letting the frame follow the
                // symbol would shove the label sideways on every third crossing.
                let symbol = HUDGlyph.symbol(for: reading)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(HUDMotion.symbolTransition(reduceMotion: reduceMotion))
                    .frame(width: 14)
                    .animation(HUDMotion.symbol(reduceMotion: reduceMotion), value: symbol)
                Text(HUDGlyph.label(for: reading.kind))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, HUDBarLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Trailing slot: the level bar, hugging the island's right edge.
struct HUDBarView: View {
    let model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = model.reading.map(HUDGlyph.barFraction(for:)) ?? 0
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule()
                .fill(.white)
                .frame(width: HUDBarLayout.fillWidth(fraction: fraction, total: HUDBarLayout.size.width))
        }
        .frame(width: HUDBarLayout.size.width, height: HUDBarLayout.size.height)
        // The fill's width is sprung, so at the top of the range the overshoot would run
        // past the track and leave a white nub sticking out of the capsule's right end.
        // Clipping to the track is what keeps the overshoot a *settle* rather than a
        // glitch; it costs nothing, since the track is this exact shape already.
        .clipShape(Capsule())
        .animation(HUDMotion.bar(reduceMotion: reduceMotion), value: fraction)
        .padding(.trailing, HUDBarLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

extension HUDViewFactory {
    /// The production slots.
    @MainActor
    static let live = HUDViewFactory(
        leading: { AnyView(HUDLeadingView(model: $0)) },
        trailing: { AnyView(HUDBarView(model: $0)) }
    )
}
