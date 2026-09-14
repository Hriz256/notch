import Testing
import HUDShared

struct BrightnessChangeClassifierTests {
    private func make(level: Double = 0.6875) -> BrightnessChangeClassifier {
        var classifier = BrightnessChangeClassifier()
        classifier.record(level: level)
        return classifier
    }

    /// The trace from the spike: 11/16 → 12/16 → 13/16 → 12/16, one notification each.
    @Test func aKeyStepIsManual() {
        var classifier = make()
        #expect(classifier.classify(level: 0.75) == .manual)
        #expect(classifier.classify(level: 0.8125) == .manual)
        #expect(classifier.classify(level: 0.75) == .manual)
    }

    @Test func aFineKeyStepIsManual() {
        var classifier = make()
        #expect(classifier.classify(level: 0.6875 + 1.0 / 64.0) == .manual)
        #expect(classifier.classify(level: 0.6875) == .manual)
    }

    /// From the spike: the sensor had left the level at 0.6737, and the first key press
    /// snapped it onto the grid at 0.6875.
    @Test func aKeyPressAfterAmbientDriftSnapsOntoTheGridAndIsManual() {
        var classifier = make(level: 0.6737)
        #expect(classifier.classify(level: 0.6875) == .manual)
    }

    /// Gentle ambient: ~0.00012 every 8 ms for three seconds, ending off the grid.
    @Test func aGentleAmbientRampIsAmbientThroughout() {
        var classifier = make()
        var level = 0.6875
        for i in 1...375 {
            level -= 0.00012
            #expect(classifier.classify(level: level) == .ambient, "step \(i)")
        }
    }

    /// Covering the sensor outright: 0.4169 → 0.9847 in 1.9 s, accelerating, steps up to
    /// 0.004 — the ramp that defeated a speed-based rule.
    @Test func aStrongAmbientRampIsAmbientThroughout() {
        var classifier = make(level: 0.4169)
        var level = 0.4169
        var step = 0.0005
        while level < 0.9847 {
            step = min(step * 1.03, 0.004)
            level = min(level + step, 0.9847)
            #expect(classifier.classify(level: level) == .ambient, "at \(level)")
        }
    }

    /// A step large enough for a key but landing off the grid is not a key.
    @Test func aLargeStepOffTheGridIsAmbient() {
        var classifier = make(level: 0.5)
        #expect(classifier.classify(level: 0.52) == .ambient)
    }

    /// A step onto the grid that is too small for a fine key step is the sensor passing
    /// through a grid point.
    @Test func aSmallStepOntoTheGridIsAmbient() {
        var classifier = make(level: 0.6860)
        #expect(classifier.classify(level: 0.6875) == .ambient)
    }

    @Test func aChangeBeforeAnyRecordIsAmbient() {
        var classifier = BrightnessChangeClassifier()
        #expect(classifier.classify(level: 0.5) == .ambient)
    }

    @Test func recordReplacesTheReferenceLevel() {
        var classifier = make()
        classifier.record(level: 0.25)
        #expect(classifier.classify(level: 0.25 + 0.0001) == .ambient)
        #expect(classifier.classify(level: 0.25 + 1.0 / 16.0) == .manual)
    }

    @Test func gridMembership() {
        #expect(BrightnessChangeClassifier.isOnGrid(0.6875))
        #expect(BrightnessChangeClassifier.isOnGrid(1.0))
        #expect(BrightnessChangeClassifier.isOnGrid(0.0))
        #expect(BrightnessChangeClassifier.isOnGrid(0.6875 + 0.0003))
        #expect(!BrightnessChangeClassifier.isOnGrid(0.6737))
        #expect(!BrightnessChangeClassifier.isOnGrid(0.6875 + 0.002))
    }
}
