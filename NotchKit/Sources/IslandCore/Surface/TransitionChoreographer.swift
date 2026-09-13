import SwiftUI
import AppKit

/// One place for every animation curve so the island always moves the same way.
public struct TransitionChoreographer: Sendable {
    /// Growing: a little bounce past the target reads as energy.
    public var geometry: Animation
    /// Shrinking: the same gesture played quicker and flatter, never a different feel and
    /// never a different anchor. It is damped short of critical on purpose — a critically
    /// damped spring *creeps* into its target instead of arriving — and the undershoot
    /// that buys is harmless, because `IslandFrame.clamped` floors every interpolated
    /// frame at the notch, so the island can never be drawn inside the hardware.
    public var collapseGeometry: Animation = Spring.collapse.animation
    /// Content arriving. A spring, never delayed: the shape and its content start in the
    /// same frame, or the island reads as a box that fills up afterwards. Quicker than the
    /// geometry spring (rule 2 of the audit's yardstick) but overlapping it, not sequenced
    /// after it.
    public var contentIn: Animation
    /// Content leaving. Still quicker than the collapse, but only slightly: an exit that
    /// finishes before the shape does leaves the user watching an *empty* panel deflate.
    public var contentOut: Animation
    /// Whether this is the Reduce Motion choreography. Content then changes by opacity
    /// alone — no scale, no offset, no blur — while the shape still resizes on the (eased)
    /// geometry curve, because the island's size *is* the information.
    public var isReduced: Bool

    /// The springs the island moves on, named and kept as numbers rather than only as
    /// `Animation` values: `Animation` cannot be introspected, so the relationships the
    /// island depends on — content quicker than the shape, the collapse the same gesture
    /// played quicker and flatter — are only assertable in this form.
    public struct Spring: Equatable, Sendable {
        public var response: Double
        public var damping: Double

        public var animation: Animation { .spring(response: response, dampingFraction: damping) }

        /// Growing. 0.42/0.78 was a touch slow and a touch loose for a 32 pt → 170 pt
        /// move: the bottom corners of a 380 pt card wobbled visibly on arrival.
        public static let grow = Spring(response: 0.38, damping: 0.82)
        /// Shrinking: the same gesture, ~0.8× the response, flat enough not to bounce but
        /// fast enough to arrive. `IslandFrame.clamped` keeps the undershoot honest.
        public static let collapse = Spring(response: 0.30, damping: 0.92)
        public static let contentIn = Spring(response: 0.26, damping: 0.9)
        public static let contentOut = Spring(response: 0.22, damping: 1.0)
    }

    public static let standard = TransitionChoreographer(
        geometry: Spring.grow.animation,
        collapseGeometry: Spring.collapse.animation,
        contentIn: Spring.contentIn.animation,
        contentOut: Spring.contentOut.animation,
        isReduced: false
    )

    public static let reducedMotion = TransitionChoreographer(
        geometry: .easeInOut(duration: 0.2),
        collapseGeometry: .easeInOut(duration: 0.2),
        contentIn: .easeInOut(duration: 0.2),
        contentOut: .easeInOut(duration: 0.15),
        isReduced: true
    )

    /// The curve for `previous -> next`: collapse when the island never grows on either axis.
    func geometryAnimation(from previous: IslandLayout?, to next: IslandLayout) -> Animation {
        guard let previous, previous.shrinks(to: next) else { return geometry }
        return collapseGeometry
    }

    @MainActor
    public static func current() -> TransitionChoreographer {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reducedMotion : .standard
    }
}

/// Where content sits the instant before it is on screen, and where it goes as it leaves.
///
/// The island is one shape growing out of the notch, so its content has to arrive the same
/// way: scaled slightly down *about its top edge* — the edge that touches the hardware —
/// and lifted a few points, so it unfolds from under the notch instead of materialising in
/// the middle of a box that is already open. Scaling about the centre, which is what a
/// default anchor does, gives the content a different origin than the shape, and two
/// origins is exactly the cue that reads as two objects.
public struct IslandContentMotion: Equatable, Sendable {
    /// Scale on the active side, about `.top`.
    public var scale: CGFloat
    /// Offset on the active side. Negative `height` sits content under the notch.
    public var offset: CGSize
    /// Blur radius on the active side. A garnish: at 13 pt type anything past ~3 pt is a
    /// smear rather than a focus pull.
    public var blur: CGFloat

    /// Opacity alone — the Reduce Motion form, and the shape of the identity side.
    public static let still = IslandContentMotion(scale: 1, offset: .zero, blur: 0)

    public static let unfoldScale: CGFloat = 0.96
    /// How far under the notch content starts, in points.
    public static let unfoldRise: CGFloat = 4
    public static let unfoldBlur: CGFloat = 2.5

    /// Content unfolding out of the notch with the shape.
    public static func unfold(isReduced: Bool) -> IslandContentMotion {
        guard !isReduced else { return .still }
        return IslandContentMotion(
            scale: unfoldScale,
            offset: CGSize(width: 0, height: -unfoldRise),
            blur: unfoldBlur
        )
    }
}

/// Fade + scale + rise (+ a touch of blur) used for content entering and leaving the island.
struct IslandContentTransition: ViewModifier {
    let motion: IslandContentMotion
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            // `.top`: the island grows from the notch, and so does what is inside it.
            .scaleEffect(active ? motion.scale : 1, anchor: .top)
            .offset(active ? motion.offset : .zero)
            .blur(radius: active ? motion.blur : 0)
    }
}

extension AnyTransition {
    static func islandContent(_ motion: IslandContentMotion) -> AnyTransition {
        .modifier(
            active: IslandContentTransition(motion: motion, active: true),
            identity: IslandContentTransition(motion: motion, active: false)
        )
    }
}
