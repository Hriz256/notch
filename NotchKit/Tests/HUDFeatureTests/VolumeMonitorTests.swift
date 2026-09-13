import HUDShared
import IslandCore
import Testing
@testable import HUDFeature

@MainActor
private final class FakeVolumeSource: VolumeDeviceSource {
    var defaultDevice: UInt32? = 1
    var samples: [UInt32: VolumeSample] = [1: VolumeSample(level: 0.5, isMuted: false)]
    private(set) var defaultHandlers: [Int: @MainActor () -> Void] = [:]
    private(set) var volumeHandlers: [Int: (device: UInt32, handler: @MainActor () -> Void)] = [:]
    private var nextID = 0

    func defaultOutputDevice() -> UInt32? { defaultDevice }
    func sample(of device: UInt32) -> VolumeSample? { samples[device] }

    func observeDefaultDevice(_ handler: @escaping @MainActor () -> Void) -> ScheduledToken {
        let id = nextID; nextID += 1
        defaultHandlers[id] = handler
        return ScheduledToken { [weak self] in self?.defaultHandlers[id] = nil }
    }

    func observeVolume(of device: UInt32, _ handler: @escaping @MainActor () -> Void) -> ScheduledToken {
        let id = nextID; nextID += 1
        volumeHandlers[id] = (device, handler)
        return ScheduledToken { [weak self] in self?.volumeHandlers[id] = nil }
    }

    func fireVolume() { for entry in volumeHandlers.values { entry.handler() } }
    func fireDefaultDevice() { for handler in defaultHandlers.values { handler() } }
}

@MainActor
struct VolumeMonitorTests {
    private func make() -> (VolumeMonitor, FakeVolumeSource, Recorder) {
        let source = FakeVolumeSource()
        let monitor = VolumeMonitor(source: source)
        let recorder = Recorder()
        monitor.onReading = { reading, initial in recorder.readings.append((reading, initial)) }
        return (monitor, source, recorder)
    }

    final class Recorder { var readings: [(HUDReading, Bool)] = [] }

    @Test func startDeliversTheCurrentLevelAsABaseline() {
        let (monitor, _, recorder) = make()
        monitor.start()
        #expect(recorder.readings.count == 1)
        #expect(recorder.readings[0].0 == HUDReading(kind: .volume, level: 0.5))
        #expect(recorder.readings[0].1 == true)
    }

    @Test func aVolumeChangeDeliversAReading() {
        let (monitor, source, recorder) = make()
        monitor.start()
        source.samples[1] = VolumeSample(level: 0.7, isMuted: true)
        source.fireVolume()
        #expect(recorder.readings.count == 2)
        #expect(recorder.readings[1].0 == HUDReading(kind: .volume, level: 0.7, isMuted: true))
        #expect(recorder.readings[1].1 == false)
    }

    @Test func aDeviceWithoutVolumeControlDeliversNothing() {
        let (monitor, source, recorder) = make()
        source.samples = [:]
        monitor.start()
        source.fireVolume()
        #expect(recorder.readings.isEmpty)
    }

    @Test func aDefaultDeviceChangeReattachesAndDeliversANewBaseline() {
        let (monitor, source, recorder) = make()
        monitor.start()
        source.defaultDevice = 2
        source.samples[2] = VolumeSample(level: 0.2, isMuted: false)
        source.fireDefaultDevice()

        #expect(recorder.readings.count == 2)
        #expect(recorder.readings[1].0.level == 0.2)
        #expect(recorder.readings[1].1 == true)
        #expect(source.volumeHandlers.count == 1)
        #expect(source.volumeHandlers.values.first?.device == 2)
    }

    @Test func stopCancelsEveryObserver() {
        let (monitor, source, recorder) = make()
        monitor.start()
        monitor.stop()
        #expect(source.defaultHandlers.isEmpty)
        #expect(source.volumeHandlers.isEmpty)
        source.fireVolume()
        #expect(recorder.readings.count == 1)
    }
}
