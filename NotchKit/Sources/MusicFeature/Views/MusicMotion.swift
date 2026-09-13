import SwiftUI
import AppKit

/// Every curve and magnitude the music island moves by, in one place — the same shape
/// `GlyphMotion` takes in the Code island and `MotionPreference` in Drop Zones.
///
/// The measurements come from the animation audit
/// (`docs/superpowers/notes/2026-09-13-animation-audit.md`): springs for anything the user
/// reads as physical, `linear` only for genuinely constant-rate fills, and a Reduce Motion
/// path that drops the travel rather than the information.
@MainActor
enum MusicMotion {
    /// Read fresh on every use rather than cached: the setting can change while the app
    /// runs, and the cost is one `NSWorkspace` property.
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Track-change peek (audit B12)

    /// The banner arriving and leaving. Reduce Motion swaps the spring for the island's own
    /// reduced curve, so nothing overshoots.
    static var trackChange: Animation {
        isReduced ? .easeInOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.85)
    }

    /// How far the banner's text rises into place. Zero under Reduce Motion: the label then
    /// cross-fades where it stands.
    static var trackChangeRise: CGFloat { isReduced ? 0 : 8 }

    /// One artwork replacing another. A cross-dissolve is already the reduced form of itself,
    /// so Reduce Motion changes nothing here.
    static let artworkDissolve: Animation = .easeInOut(duration: 0.25)
}
