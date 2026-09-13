import SwiftUI

/// Every curve the HUD animates on, in one place so the spec's numbers are assertable
/// without a renderer.
///
/// Both entry points take Reduce Motion as a parameter rather than reading it: the views
/// already have it from the environment, and a pure function is the half that can be
/// tested.
enum HUDMotion {
    // MARK: - The symbol (audit B3)

    /// The level symbol changes as the volume crosses the thirds
    /// (`speaker.slash` → `wave.1` → `wave.2` → `wave.3`). A swap at 12 pt is a flicker;
    /// the symbol renderer's own replace effect morphs one glyph into the next instead,
    /// which is what the system's volume HUD does.
    ///
    /// Content, not shape, so it is quick and flat: it must be over before the user has
    /// finished pressing the next volume key.
    static let symbolResponse: Double = 0.2
    static let symbolDamping: Double = 1.0

    /// `.replace` needs an animated transaction to run in; without one the glyph cuts.
    static func symbol(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: symbolResponse, dampingFraction: symbolDamping)
    }

    /// Reduce Motion gets a plain swap: `.identity` keeps the new glyph and skips both the
    /// morph and the cross-fade `.replace` would otherwise degrade to.
    static func symbolTransition(reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .identity : .symbolEffect(.replace.downUp)
    }

    /// Whether the glyph morphs at all — the boolean half of ``symbolTransition(reduceMotion:)``,
    /// separated out because `ContentTransition` is opaque to a test.
    static func morphsSymbol(reduceMotion: Bool) -> Bool { !reduceMotion }
}
