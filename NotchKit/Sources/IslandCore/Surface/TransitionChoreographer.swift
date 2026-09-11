import SwiftUI
import AppKit

/// One place for every animation curve so the island always moves the same way.
public struct TransitionChoreographer: Sendable {
    /// Growing: bouncy is fine, an overshoot past the target reads as energy.
    public var geometry: Animation
    /// Shrinking: critically damped. A bouncy spring undershoots, and an undershoot below
    /// the notch draws the island *inside* the physical notch and exposes its edges.
    public var collapseGeometry: Animation = .spring(response: 0.38, dampingFraction: 1.0)
    public var contentIn: Animation
    public var contentOut: Animation
    public var usesBlur: Bool

    public static let standard = TransitionChoreographer(
        geometry: .spring(response: 0.42, dampingFraction: 0.78),
        collapseGeometry: .spring(response: 0.38, dampingFraction: 1.0),
        contentIn: .easeOut(duration: 0.18).delay(0.06),
        contentOut: .easeIn(duration: 0.12),
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
