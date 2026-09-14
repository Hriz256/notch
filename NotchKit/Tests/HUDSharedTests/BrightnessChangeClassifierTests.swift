import Foundation
import Testing
import HUDShared

struct BrightnessChangeClassifierTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(level: Double = 0.6875) -> BrightnessChangeClassifier {
        var classifier = BrightnessChangeClassifier()
        classifier.record(level: level, at: t0)
        return classifier
    }

    /// The trace from the spike: 11/16 → 12/16 → 13/16 → 12/16, one notification each.
    @Test func aKeyStepIsManual() {
        var classifier = make()
        #expect(classifier.classify(level: 0.75, at: t0.addingTimeInterval(0.3)) == .manual)
        #expect(classifier.classify(level: 0.8125, at: t0.addingTimeInterval(0.5)) == .manual)
        #expect(classifier.classify(level: 0.75, at: t0.addingTimeInterval(0.7)) == .manual)
    }

    @Test func aFineKeyStepIsManual() {
        var classifier = make()
        #expect(classifier.classify(level: 0.6875 + 1.0 / 64.0, at: t0.addingTimeInterval(1)) == .manual)
        #expect(classifier.classify(level: 0.6875, at: t0.addingTimeInterval(2)) == .manual)
    }

    /// Ambient: ~0.00012 every 8 ms for three seconds, as measured, ending off the grid.
    @Test func anAmbientRampIsAmbientThroughout() {
        var classifier = make()
        var level = 0.6875
        for i in 1...375 {
            level -= 0.00012
            let verdict = classifier.classify(level: level, at: t0.addingTimeInterval(Double(i) * 0.008))
            #expect(verdict == .ambient, "step \(i)")
        }
    }

    /// The fastest ramp seen (uncovering the sensor): 0.127 in 4.1 s, ~0.00025 per 8 ms.
    @Test func theFastestAmbientRampIsStillAmbient() {
        var classifier = make(level: 0.6255)
        var level = 0.6255
        for i in 1...512 {
            level += 0.127 / 512
            let verdict = classifier.classify(level: level, at: t0.addingTimeInterval(Double(i) * 0.008))
            #expect(verdict == .ambient, "step \(i)")
        }
    }

    /// Hardware that smooths a key press into a short ramp: 1/16 over 250 ms.
    @Test func aSmoothedKeyStepIsManualBeforeItSettles() {
        var classifier = make()
        var level = 0.6875
        var verdicts: [BrightnessChangeClassifier.Verdict] = []
        for i in 1...30 {
            level += (1.0 / 16.0) / 30
            verdicts.append(classifier.classify(level: level, at: t0.addingTimeInterval(Double(i) * 0.008)))
        }
        #expect(verdicts.contains(.manual))
        // It is caught by the time the ramp has covered half a key step, not at its end.
        #expect(verdicts.firstIndex(of: .manual)! < 20)
    }

    /// After a key press the sensor keeps creeping; the key's jump must not make the creep
    /// look manual for the rest of the window.
    @Test func creepAfterAKeyPressIsAmbient() {
        var classifier = make()
        #expect(classifier.classify(level: 0.75, at: t0.addingTimeInterval(0.1)) == .manual)
        #expect(classifier.classify(level: 0.74988, at: t0.addingTimeInterval(0.108)) == .ambient)
        #expect(classifier.classify(level: 0.74976, at: t0.addingTimeInterval(0.116)) == .ambient)
    }

    @Test func aChangeBeforeAnyRecordIsAmbient() {
        var classifier = BrightnessChangeClassifier()
        #expect(classifier.classify(level: 0.5, at: t0) == .ambient)
    }

    @Test func recordResetsTheWindow() {
        var classifier = make()
        classifier.record(level: 0.2, at: t0.addingTimeInterval(5))
        #expect(classifier.classify(level: 0.2 + 0.0001, at: t0.addingTimeInterval(5.008)) == .ambient)
        #expect(classifier.classify(level: 0.2 + 1.0 / 16.0, at: t0.addingTimeInterval(5.2)) == .manual)
    }
}
