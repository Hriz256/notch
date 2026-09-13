import HUDShared
import SwiftUI
import Testing

@testable import HUDFeature

/// The HUD's curves. `Animation` is `Equatable`, so the spec's constants can be asserted
/// without a renderer; the morph itself is checked through its boolean twin because
/// `ContentTransition` is opaque.
@Suite("HUD motion")
struct HUDMotionTests {

    // MARK: - The symbol morph (audit B3)

    @Test("The glyph morphs on a quick, flat spring so it is over before the next key press")
    func symbolCurve() {
        #expect(HUDMotion.symbol(reduceMotion: false)
            == .spring(response: 0.2, dampingFraction: 1.0))
        #expect(HUDMotion.symbolResponse == 0.2)
        #expect(HUDMotion.symbolDamping == 1.0)
    }

    @Test("Reduce Motion swaps the glyph plainly: no animation and no replace effect")
    func symbolUnderReduceMotion() {
        #expect(HUDMotion.symbol(reduceMotion: true) == nil)
        #expect(HUDMotion.morphsSymbol(reduceMotion: true) == false)
        #expect(HUDMotion.morphsSymbol(reduceMotion: false) == true)
    }

    @Test("There is something to morph: each third of the volume range draws its own glyph")
    func symbolsDifferAcrossThirds() {
        let symbols = [0.0, 0.2, 0.5, 0.9].map {
            HUDGlyph.symbol(for: HUDReading(kind: .volume, level: $0))
        }
        #expect(Set(symbols).count == symbols.count)
    }

    // MARK: - The bar's overshoot (audit B8, owner's call)

    @Test("The fill is sprung so it runs past the new level and settles")
    func barCurve() {
        #expect(HUDMotion.bar(reduceMotion: false)
            == .spring(response: 0.24, dampingFraction: 0.72))
        #expect(HUDMotion.barResponse == 0.24)
        #expect(HUDMotion.barDamping == 0.72)
    }

    @Test("Reduce Motion still cuts the fill to the level, as the spec has always said")
    func barUnderReduceMotion() {
        #expect(HUDMotion.bar(reduceMotion: true) == nil)
    }

    /// The spring overshoots the *width*, which the view clips to the track. The target it
    /// overshoots from and returns to is still clamped here, so a level the monitors
    /// report out of range can never park the fill outside the capsule.
    @Test("Whatever the level, the fill's resting width is inside the track")
    func fillWidthNeverLeavesTheTrack() {
        let total = HUDBarLayout.size.width
        for fraction in [-1.0, -0.06, 0, 0.5, 1, 1.06, 4, .infinity, .nan] {
            let width = HUDBarLayout.fillWidth(fraction: fraction, total: total)
            #expect(width >= 0 && width <= total)
        }
    }
}
