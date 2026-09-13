import SwiftUI

/// How dropped tiles arrive — the curve, and how far apart they arrive.
///
/// Pulled out of the views because the interesting half is arithmetic: the stagger is
/// *derived* from how long the card it plays in stays on screen, not picked, and that
/// derivation is the thing worth asserting.
enum SettleMotion {
    // MARK: - The curve (audit A8)

    /// Dropped thumbnails used to arrive on `.easeOut(duration: 0.3)`: they decelerated
    /// into the target and stopped dead. `1.12 → 1` wants to *settle* — overshoot slightly
    /// under the resting size and come back — which is what makes a drop read as caught
    /// rather than parked.
    static let response: Double = 0.4
    static let damping: Double = 0.75

    /// How long one tile's spring takes to become visually still.
    ///
    /// With ζ = 0.75 and this response the envelope `e^(−ζ·ωn·t)` is under 3 % by 0.3 s,
    /// and 3 % of a 0.12 displacement is a tenth of a point — invisible. This is the
    /// number the stagger budget is spent against, not the nominal `response`.
    static let visualRise: Double = 0.3

    // MARK: - The stagger (audit B9)

    /// What B9 asks for: tiles land about 40 ms apart, newest first.
    static let nominalStagger: Double = 0.04

    /// The settle card's whole life — `DropZonesViewModel.settleDelay`, which the audit's
    /// "what I will not touch" list pins at 400 ms. The last tile has to be *still* before
    /// the island starts collapsing, so only what is left of the window once one tile's
    /// rise is paid for can go to the stagger.
    static let settleWindow: Double = 0.4
    static var settleSpan: Double { max(settleWindow - visualRise, 0) }

    /// B9's own cap for the hover-expanded row, which has no window of its own but has up
    /// to seven boxes: the whole fan-in is over within a fifth of a second, or the row
    /// reads as slow.
    static let rowSpan: Double = 0.2

    /// How far apart consecutive tiles land — the nominal 40 ms, shortened when `count`
    /// tiles at 40 ms would not fit inside `span`.
    static func stagger(count: Int, span: Double) -> Double {
        guard count > 1, span > 0 else { return 0 }
        return min(nominalStagger, span / Double(count - 1))
    }

    /// When the tile at `index` starts. Index 0 is the newest file and never waits.
    static func delay(index: Int, count: Int, span: Double) -> Double {
        guard count > 1, index > 0 else { return 0 }
        return Double(min(index, count - 1)) * stagger(count: count, span: span)
    }

    /// The whole fan-in, from the first tile starting to the last one being still.
    static func totalDuration(count: Int, span: Double) -> Double {
        delay(index: count - 1, count: count, span: span) + visualRise
    }

    // MARK: - The animations the views ask for

    /// Reduce Motion keeps the information and drops the movement: the tiles fade in
    /// together, at rest, at their resting size.
    static let fadeDuration: Double = 0.18

    static func entrance(index: Int, count: Int, span: Double, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return .easeOut(duration: fadeDuration) }
        let spring = Animation.spring(response: response, dampingFraction: damping)
        // `.delay(0)` is not the same animation as no delay at all — it wraps the spring —
        // so the tile that never waits is handed the bare spring.
        let wait = delay(index: index, count: count, span: span)
        return wait > 0 ? spring.delay(wait) : spring
    }
}

// MARK: - The modifier

/// Plays one tile's arrival once, the first time it is laid out.
///
/// Per *tile* rather than per stack, which is the whole point of B9: a single transform on
/// the container cannot stagger. The state flips in `onAppear`, so a stack rebuilt under a
/// new identity — which is what `ZoneCardView` does on a second drop — replays it, and a
/// tile inserted into a row that is already up plays its own arrival alone.
struct SettleEntrance: ViewModifier {
    let index: Int
    let count: Int
    let span: Double
    /// The scale the tile arrives from: above 1 for a drop that lands (the settle card),
    /// below 1 for a row growing into place.
    let fromScale: CGFloat
    /// Whether the tile fades in as well *while it is moving*. The settle card's tiles do
    /// not — a file that just landed is solid — while the row's grow out of nothing.
    /// Reduce Motion fades either way: it is the whole of the reduced entrance.
    let fades: Bool

    @State private var hasEntered = false

    func body(content: Content) -> some View {
        let reduced = MotionPreference.isReduced
        let entering = !hasEntered
        return content
            .scaleEffect(entering && !reduced ? fromScale : 1)
            .opacity(entering && (fades || reduced) ? 0 : 1)
            .animation(
                SettleMotion.entrance(
                    index: index, count: count, span: span, reduceMotion: reduced
                ),
                value: hasEntered
            )
            .onAppear { hasEntered = true }
    }
}

extension View {
    /// - Parameter isEnabled: `false` leaves the tile exactly as it is, for the peek fan
    ///   and the zone card, which are not arrivals.
    @ViewBuilder
    func settleEntrance(
        index: Int,
        count: Int,
        span: Double,
        fromScale: CGFloat,
        fades: Bool,
        isEnabled: Bool = true
    ) -> some View {
        if isEnabled {
            modifier(
                SettleEntrance(
                    index: index, count: count, span: span, fromScale: fromScale, fades: fades
                )
            )
        } else {
            self
        }
    }
}
