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

    private func make() -> (BrightnessMonitor, FakeBrightnessSource, Recorder) {
        let source = FakeBrightnessSource()
        let monitor = BrightnessMonitor(source: source)
        let recorder = Recorder()
        monitor.onReading = { reading, initial in recorder.readings.append((reading, initial)) }
        return (monitor, source, recorder)
    }

    @Test func startDeliversTheCurrentLevelAsABaseline() {
        let (monitor, _, recorder) = make()
        monitor.start()
        #expect(recorder.readings.count == 1)
        #expect(recorder.readings[0].0 == HUDReading(kind: .brightness, level: 0.8))
        #expect(recorder.readings[0].1 == true)
    }

    @Test func aChangeDeliversAReading() {
        let (monitor, source, recorder) = make()
        monitor.start()
        source.level = 0.4
        source.fire()
        #expect(recorder.readings.count == 2)
        #expect(recorder.readings[1].0 == HUDReading(kind: .brightness, level: 0.4))
        #expect(recorder.readings[1].1 == false)
    }

    @Test func unavailableSourceDeliversNothing() {
        let (monitor, source, recorder) = make()
        source.isAvailable = false
        monitor.start()
        source.fire()
        #expect(recorder.readings.isEmpty)
        #expect(source.handler == nil)
    }

    @Test func failedRegistrationDeliversNothing() {
        let (monitor, source, recorder) = make()
        source.registrationSucceeds = false
        monitor.start()
        #expect(recorder.readings.isEmpty)
    }

    @Test func aSecondStartIsANoOpButARestartObservesAgain() {
        let (monitor, source, recorder) = make()
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
        let (monitor, source, recorder) = make()
        monitor.start()
        let handler = source.handler
        monitor.stop()
        #expect(source.stopCount == 1)
        source.level = 0.1
        handler?()
        #expect(recorder.readings.count == 1)
    }
}
