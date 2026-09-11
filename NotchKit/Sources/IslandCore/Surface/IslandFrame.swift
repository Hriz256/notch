import SwiftUI

/// Animatable frame with a hard floor.
///
/// `Animatable` makes SwiftUI interpolate `size` (and `flare`) itself, so `body` runs once
/// per displayed frame with the in-between values. Clamping there — rather than clamping the
/// endpoints — means a spring that undershoots its target can never draw the island smaller
/// than the physical notch, which would expose the notch edges for a few frames.
///
/// `flare` is the shape's top radius: `NotchShape`'s rect includes the outward flares, so the
/// drawn body is `frame.width - 2 * flare`. Adding the flare *after* the clamp keeps the floor
/// on the body, and animating it here in lockstep with `NotchShape.animatableData` keeps the
/// two in sync for every intermediate frame.
/// The `Animatable` conformance is main-actor isolated: `ViewModifier` already pins the type to
/// the main actor, and SwiftUI only interpolates while rendering there.
struct IslandFrame: ViewModifier, @MainActor Animatable {
    var size: CGSize
    var flare: CGFloat
    let minimum: CGSize
    let alignment: Alignment

    init(size: CGSize, flare: CGFloat = 0, minimum: CGSize, alignment: Alignment = .center) {
        self.size = size
        self.flare = flare
        self.minimum = minimum
        self.alignment = alignment
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), flare) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            flare = newValue.second
        }
    }

    /// Per-axis floor. Pure so the clamp can be tested without a render pass.
    static func clamped(size: CGSize, minimum: CGSize) -> CGSize {
        CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
    }

    func body(content: Content) -> some View {
        let floored = Self.clamped(size: size, minimum: minimum)
        return content.frame(width: floored.width + 2 * flare, height: floored.height, alignment: alignment)
    }
}

extension View {
    /// Sizes the view to `size`, never below `minimum`, widening by `2 * flare` for the
    /// `NotchShape` flares. Interpolated frame-by-frame while an animation is in flight.
    func islandFrame(size: CGSize, flare: CGFloat = 0, minimum: CGSize, alignment: Alignment = .center) -> some View {
        modifier(IslandFrame(size: size, flare: flare, minimum: minimum, alignment: alignment))
    }
}
