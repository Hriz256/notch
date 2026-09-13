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

    // MARK: - The bar (audit B8)

    /// The fill runs slightly past the new level and settles, instead of decelerating into
    /// it and stopping dead.
    ///
    /// This is a **deliberate departure from the system HUD**, whose bar does not
    /// overshoot: the owner took the audit's optional B8 on the grounds that it is
    /// juicier than macOS. The spec's "The bar" row carries the same note.
    ///
    /// 0.24 keeps it inside the 0.12 s the spec used to ask for *perceptually* — the fill
    /// is past the new level within about a tenth of a second and only the tail is late —
    /// so holding a volume key still reads as a continuous slide rather than a queue of
    /// springs; 0.72 is one visible overshoot and no wobble.
    static let barResponse: Double = 0.24
    static let barDamping: Double = 0.72

    /// Reduce Motion drops the animation entirely, as the spec has always said: the fill
    /// cuts to the new level.
    static func bar(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: barResponse, dampingFraction: barDamping)
    }
}
