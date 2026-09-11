import SwiftUI

/// The colors the coding-agent island draws with.
///
/// Kept in one place so the compact island, the usage panel and the activity panel
/// cannot drift apart — every accent below is referenced by at least two views.
enum CodePalette {
    /// The Claude salmon: agent sprite, session ring, usage bars, sparkline.
    static let salmon = Color(red: 0.96, green: 0.63, blue: 0.54)
    /// "Waiting for you" — the one stage that needs the user.
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.3)
    /// Success: the completion glyph and the "You're good" pace label.
    static let green = Color(red: 0.28, green: 0.82, blue: 0.48)
    /// Failure: the failed glyph and the "Slow down" pace label.
    static let red = Color(red: 1.0, green: 0.36, blue: 0.36)
}
