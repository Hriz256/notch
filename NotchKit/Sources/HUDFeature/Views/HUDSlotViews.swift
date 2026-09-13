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
            BarFill(width: HUDBarLayout.fillWidth(fraction: fraction, total: HUDBarLayout.size.width))
        }
        .frame(width: HUDBarLayout.size.width, height: HUDBarLayout.size.height)
        // The fill's width is sprung, so at the *top* of the range the overshoot would run
        // past the track and leave a white nub sticking out of the capsule's right end.
        // Clipping to the track is what keeps the overshoot a settle rather than a glitch;
        // it costs nothing, since the track is this exact shape already. The bottom of the
        // range is `BarFill`'s job — a clip cannot rescue a negative width.
        .clipShape(Capsule())
        .animation(HUDMotion.bar(reduceMotion: reduceMotion), value: fraction)
        .padding(.trailing, HUDBarLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// The white part of the bar, at a width the spring is allowed to undershoot.
///
/// The spring's other end is the problem a clip cannot solve: muting, or dropping the
/// volume to zero, makes ζ = 0.72 undershoot by about 3.8 % of the displacement, so for a
/// few frames `.frame(width:)` is handed a *negative* number and SwiftUI logs
/// "Invalid frame dimension". Interpolating the width here and clamping it at the floor is
/// what keeps the spring's tail legal; the bar simply rests at empty for those frames.
///
/// It has to be a view of its own: `.frame(width: max(0, …))` in the parent would clamp
/// the *target*, not the values SwiftUI interpolates through on the way to it. And it has
/// to be a width rather than a `scaleEffect(x:)`, which would squash the capsule's rounded
/// ends into ellipses on the way past.
///
/// The conformance is main-actor isolated, as `IslandFrame`'s is and for the same reason:
/// `View` already pins the type to the main actor, and SwiftUI only interpolates while
/// rendering there.
private struct BarFill: View, @MainActor Animatable {
    var width: CGFloat

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: max(0, width))
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
