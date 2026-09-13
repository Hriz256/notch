import SwiftUI
import AppKit

/// One place for every animation curve so the island always moves the same way.
public struct TransitionChoreographer: Sendable {
    /// Growing: bouncy is fine, an overshoot past the target reads as energy.
    public var geometry: Animation
    /// Shrinking: critically damped. A bouncy spring undershoots, and an undershoot below
    /// the notch draws the island *inside* the physical notch and exposes its edges.
    public var collapseGeometry: Animation = .spring(response: 0.38, dampingFraction: 1.0)
    /// Content arriving. A spring, never delayed: the shape and its content start in the
    /// same frame, or the island reads as a box that fills up afterwards. Quicker than the
    /// geometry spring (rule 2 of the audit's yardstick) but overlapping it, not sequenced
    /// after it.
    public var contentIn: Animation
    /// Content leaving. Still quicker than the collapse, but only slightly: an exit that
    /// finishes before the shape does leaves the user watching an *empty* panel deflate.
    public var contentOut: Animation
    public var usesBlur: Bool

    /// The springs the island moves on, named and kept as numbers rather than only as
    /// `Animation` values: `Animation` cannot be introspected, so the relationships the
    /// island depends on — content quicker than the shape, the collapse the same gesture
    /// played quicker and flatter — are only assertable in this form.
    public struct Spring: Equatable, Sendable {
        public var response: Double
        public var damping: Double

        public var animation: Animation { .spring(response: response, dampingFraction: damping) }

        /// Growing: a little bounce past the target reads as energy.
        public static let grow = Spring(response: 0.42, damping: 0.78)
        /// Shrinking: the same gesture, flatter. `IslandFrame.clamped` floors every
        /// interpolated frame at the notch, so an undershoot can never expose its edges.
        public static let collapse = Spring(response: 0.38, damping: 1.0)
        public static let contentIn = Spring(response: 0.26, damping: 0.9)
        public static let contentOut = Spring(response: 0.22, damping: 1.0)
    }

    public static let standard = TransitionChoreographer(
        geometry: Spring.grow.animation,
        collapseGeometry: Spring.collapse.animation,
        contentIn: Spring.contentIn.animation,
        contentOut: Spring.contentOut.animation,
        usesBlur: true
    )

    public static let reducedMotion = TransitionChoreographer(
        geometry: .easeInOut(duration: 0.2),
        collapseGeometry: .easeInOut(duration: 0.2),
        contentIn: .easeInOut(duration: 0.2),
        contentOut: .easeInOut(duration: 0.15),
        usesBlur: false
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

/// Fade + slight scale + blur used for content entering/leaving the island.
struct IslandContentTransition: ViewModifier {
    let active: Bool
    let usesBlur: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.94 : 1)
            .blur(radius: active && usesBlur ? 6 : 0)
    }
}

extension AnyTransition {
    static func islandContent(usesBlur: Bool) -> AnyTransition {
        .modifier(
            active: IslandContentTransition(active: true, usesBlur: usesBlur),
            identity: IslandContentTransition(active: false, usesBlur: usesBlur)
        )
    }
}
