import Foundation
import HUDShared
import Testing
@testable import HUDFeature

@MainActor
private final class FakeBrightnessSource: BrightnessSource {
    var isAvailable = true
    var level: Double? = 0.8
    var registrationSucceeds = true
    private(set) var handler: (@MainActor () -> Void)?
    private(set) var observeCount = 0
    private(set) var stopCount = 0

    func brightness() -> Double? { level }
    func observe(_ handler: @escaping @MainActor () -> Void) -> Bool {
        observeCount += 1
        guard registrationSucceeds else { return false }
        self.handler = handler
        return true
    }
    func stopObserving() { handler = nil; stopCount += 1 }
    func fire() { handler?() }
}

@MainActor
struct BrightnessMonitorTests {
    final class Recorder { var readings: [(HUDReading, Bool)] = [] }

    final class Clock { var now = Date(timeIntervalSince1970: 1_700_000_000) }

    private func make() -> (BrightnessMonitor, FakeBrightnessSource, Recorder, Clock) {
        let source = FakeBrightnessSource()
        let clock = Clock()
        let monitor = BrightnessMonitor(source: source, now: { clock.now })
        let recorder = Recorder()
        monitor.onReading = { reading, initial in recorder.readings.append((reading, initial)) }
        return (monitor, source, recorder, clock)
    }

    @Test func startDeliversTheCurrentLevelAsABaseline() {
        let (monitor, _, recorder, _) = make()
        monitor.start()
        #expect(recorder.readings.count == 1)
        #expect(recorder.readings[0].0 == HUDReading(kind: .brightness, level: 0.8))
        #expect(recorder.readings[0].1 == true)
    }

    @Test func aChangeDeliversAReading() {
        let (monitor, source, recorder, _) = make()
        monitor.start()
        source.level = 0.4
        source.fire()
        #expect(recorder.readings.count == 2)
        #expect(recorder.readings[1].0 == HUDReading(kind: .brightness, level: 0.4))
        #expect(recorder.readings[1].1 == false)
    }

    /// The sensor's ramp — tiny steps every 8 ms — never reaches the session, so it never
    /// presents a HUD. A key press right after it does, with the level the keys left.
    @Test func ambientCreepIsDroppedButAKeyPressGetsThrough() {
        let (monitor, source, recorder, clock) = make()
        monitor.start()
        var level = 0.8
        for _ in 1...100 {
            level -= 0.00012
            clock.now.addTimeInterval(0.008)
            source.level = level
            source.fire()
        }
        #expect(recorder.readings.count == 1)

        clock.now.addTimeInterval(0.5)
        source.level = level - 1.0 / 16.0
        source.fire()
        #expect(recorder.readings.count == 2)
        #expect(recorder.readings[1].0.level == level - 1.0 / 16.0)
        #expect(recorder.readings[1].1 == false)
    }

    @Test func unavailableSourceDeliversNothing() {
        let (monitor, source, recorder, _) = make()
        source.isAvailable = false
        monitor.start()
        source.fire()
        #expect(recorder.readings.isEmpty)
        #expect(source.handler == nil)
    }

    @Test func failedRegistrationDeliversNothing() {
        let (monitor, source, recorder, _) = make()
        source.registrationSucceeds = false
        monitor.start()
        #expect(recorder.readings.isEmpty)
    }

    @Test func aSecondStartIsANoOpButARestartObservesAgain() {
        let (monitor, source, recorder, _) = make()
        monitor.start()
        monitor.start()
        #expect(source.observeCount == 1)
        #expect(recorder.readings.count == 1)

        monitor.stop()
        monitor.start()
        #expect(source.observeCount == 2)
        #expect(recorder.readings.count == 2)
        #expect(recorder.readings[1].1 == true)
    }

    @Test func stopUnregistersAndDropsLateCallbacks() {
        let (monitor, source, recorder, _) = make()
        monitor.start()
        let handler = source.handler
        monitor.stop()
        #expect(source.stopCount == 1)
        source.level = 0.1
        handler?()
        #expect(recorder.readings.count == 1)
    }
}
