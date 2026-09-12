import SwiftUI

/// The colours the drop-zones island draws with.
///
/// One accent for the whole feature, and it is the system's: Seam's zones are drawn in
/// `.systemBlue` so they read as a drop target the way every other macOS drop target
/// does, and taking the colour from the system means they follow the user's accent and
/// increase-contrast settings for free.
enum Palette {
    /// The one accent: card strokes, icons, labels, the count badge.
    static let blue = Color(nsColor: .systemBlue)
    /// An untargeted card's fill — barely there over the island's black, just enough to
    /// separate the card from the panel around it.
    static let cardFill = blue.opacity(0.06)
    /// The targeted card's fill: twice the tint, which together with the extra width and
    /// the 1.02 scale is what says "let go here".
    static let cardFillTargeted = blue.opacity(0.12)
    /// Secondary text — only the stash caption under the hover-expanded card.
    static let caption = Color.white.opacity(0.7)
    /// The hairline around a thumbnail, so a dark image still has an edge against the
    /// island's black.
    static let thumbStroke = Color.white.opacity(0.18)
}
