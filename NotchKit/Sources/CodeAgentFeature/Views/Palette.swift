import AppKit
import SwiftUI

/// The colors the coding-agent island draws with.
///
/// Kept in one place so the compact island, the usage panel and the activity panel
/// cannot drift apart — every accent below is referenced by at least two views.
enum CodePalette {
    /// One colour, stated once, in the two forms the island needs it: SwiftUI's for the
    /// views and AppKit's for the `CALayer`s the activity glyphs animate on. Both are sRGB,
    /// which is the space `Color(red:green:blue:)` has always used here.
    struct Ink: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }
        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
        var cgColor: CGColor { nsColor.cgColor }
    }

    /// The Claude salmon: agent sprite, session ring, usage bars, sparkline.
    static let salmonInk = Ink(red: 0.96, green: 0.63, blue: 0.54)
    /// "Waiting for you" — the one stage that needs the user.
    static let amberInk = Ink(red: 1.0, green: 0.72, blue: 0.3)
    /// Success: the completion glyph and the "You're good" pace label.
    static let greenInk = Ink(red: 0.28, green: 0.82, blue: 0.48)
    /// Failure: the failed glyph and the "Slow down" pace label.
    static let redInk = Ink(red: 1.0, green: 0.36, blue: 0.36)

    static let salmon = salmonInk.color
    static let amber = amberInk.color
    static let green = greenInk.color
    static let red = redInk.color
}
