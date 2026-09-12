import CoreGraphics

/// Which of the surface's two windows draws the island, as three plain numbers.
///
/// The island normally lives in a private SkyLight Space at absolute level 400, and
/// everything in that Space composites *above* the system's drag-image window: the file
/// thumbnail in the user's hand vanishes behind the zones panel (Seam shows it on top).
/// An ordinary-Space panel at the same window level does not have the problem — including
/// one that fades in while the drag is already in flight, which is what makes the swap
/// possible at all.
///
/// So the surface keeps a second, identical window that is never adopted into the private
/// Space, and for the length of a drag the two trade places: the mirror gets the content
/// view and full alpha, the primary goes transparent. Both hosting views render the same
/// presenter state, so the swap is pixel-identical as long as it happens while the island
/// is static — which is why it is armed at drag *start* rather than when the zones open.
///
/// The arithmetic is pulled out here because `SurfaceController` cannot be built without
/// real windows and a real notch screen, and this is the part worth checking.
public struct MirrorSwap: Equatable, Sendable {
    /// Alpha for the primary window — the one adopted into the private Space.
    public let primaryAlpha: CGFloat
    /// Alpha for the mirror window, which lives in the ordinary user Space.
    public let mirrorAlpha: CGFloat
    /// Whether the mirror carries a hosting view at all. It is torn down when inactive so
    /// an idle mirror costs no SwiftUI rendering — it is an empty transparent window.
    public let mirrorHasContent: Bool

    public static func resolve(mirrored: Bool) -> MirrorSwap {
        mirrored
            ? MirrorSwap(primaryAlpha: 0, mirrorAlpha: 1, mirrorHasContent: true)
            : MirrorSwap(primaryAlpha: 1, mirrorAlpha: 0, mirrorHasContent: false)
    }
}
