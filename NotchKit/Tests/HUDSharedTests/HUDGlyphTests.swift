import Testing
@testable import HUDShared

struct HUDGlyphTests {
    @Test func labelsAreSeamsCopy() {
        #expect(HUDGlyph.label(for: .volume) == "Sound")
        #expect(HUDGlyph.label(for: .brightness) == "Brightness")
    }

    @Test func brightnessAlwaysUsesTheSun() {
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .brightness, level: 0)) == "sun.max.fill")
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .brightness, level: 1)) == "sun.max.fill")
    }

    @Test func volumeSymbolFollowsThirds() {
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .volume, level: 0)) == "speaker.slash.fill")
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .volume, level: 0.2)) == "speaker.wave.1.fill")
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .volume, level: 1.0 / 3.0)) == "speaker.wave.2.fill")
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .volume, level: 0.5)) == "speaker.wave.2.fill")
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .volume, level: 2.0 / 3.0)) == "speaker.wave.3.fill")
        #expect(HUDGlyph.symbol(for: HUDReading(kind: .volume, level: 1)) == "speaker.wave.3.fill")
    }

    @Test func mutedOverridesTheLevel() {
        let muted = HUDReading(kind: .volume, level: 0.8, isMuted: true)
        #expect(HUDGlyph.symbol(for: muted) == "speaker.slash.fill")
        #expect(HUDGlyph.barFraction(for: muted) == 0)
        #expect(HUDGlyph.barFraction(for: HUDReading(kind: .volume, level: 0.8)) == 0.8)
    }

    @Test func readingClampsAndIgnoresMuteForBrightness() {
        #expect(HUDReading(kind: .volume, level: 1.7).level == 1)
        #expect(HUDReading(kind: .volume, level: -0.2).level == 0)
        #expect(HUDReading(kind: .volume, level: .nan).level == 0)
        #expect(HUDReading(kind: .brightness, level: 0.5, isMuted: true).isMuted == false)
    }
}
