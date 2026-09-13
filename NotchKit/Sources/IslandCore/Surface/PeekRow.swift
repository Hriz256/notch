import SwiftUI

/// The peek island's content: one ``slotWidth``-wide slot hugging each edge of the island,
/// with the notch between them.
///
/// The row **fills** the width it is proposed instead of measuring a fixed
/// `notch + 2 * slot`. That distinction only shows up while the island's width is in
/// flight: `IslandFrame` interpolates the width frame by frame, and a fixed-width row stays
/// centred on the notch while the island's edges slide past it — so for the whole length of
/// every peek ↔ expanded transition each glyph walks toward the notch. At the Code card's
/// 380 pt expanded width the leading glyph ends up 69 pt from the island's left edge
/// instead of 28, close enough to the notch to read as sitting under it.
///
/// Filling glues each slot to the edge it belongs to at every intermediate width. The gap
/// is a `Spacer` with the notch as its *minimum* rather than its exact width, so the row
/// still measures `notch + 2 * slot` when it is proposed less than that (collapsing, where
/// the island clips the row anyway) and the two glyphs can never meet behind the notch.
///
/// The row is `public` because features build the same two-slot geometry inside their own
/// *expanded* views: the hover-expanded card has to put its glyphs at exactly the peek's
/// positions, and re-deriving that layout per feature is how the two drift apart.
public struct PeekRow: View {
    public let leading: AnyView
    public let trailing: AnyView
    public let notch: CGSize
    /// How wide each slot is. Matches the presentation's ``Presentation/peekSlotWidth`` so the
    /// row's two slots fill exactly the width the layout gave the island either side of the notch.
    public let slotWidth: CGFloat

    public init(leading: AnyView, trailing: AnyView, notch: CGSize,
                slotWidth: CGFloat = IslandLayout.peekSlotWidth) {
        self.leading = leading
        self.trailing = trailing
        self.notch = notch
        self.slotWidth = slotWidth
    }

    public var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: slotWidth, height: notch.height)
            Spacer(minLength: notch.width)
            trailing
                .frame(width: slotWidth, height: notch.height)
        }
        .frame(maxWidth: .infinity)
    }
}
