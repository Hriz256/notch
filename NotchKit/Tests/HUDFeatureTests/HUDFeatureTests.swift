import Foundation
import HUDShared
import IslandCore
import Testing
@testable import HUDFeature

@MainActor
private final class FakeVolumeSource: VolumeDeviceSource {
    var handlers: [@MainActor () -> Void] = []
    var level = 0.5
    func defaultOutputDevice() -> UInt32? { 1 }
    func sample(of device: UInt32) -> VolumeSample? { VolumeSample(level: level, isMuted: false) }
    func observeDefaultDevice(_ handler: @escaping @MainActor () -> Void) -> ScheduledToken { ScheduledToken {} }
    func observeVolume(of device: UInt32, _ handler: @escaping @MainActor () -> Void) -> ScheduledToken {
        handlers.append(handler)
        return ScheduledToken { [weak self] in self?.handlers.removeAll() }
    }
    func fire() { for handler in handlers { handler() } }
}

@MainActor
private final class FakeBrightnessSource: BrightnessSource {
    var isAvailable = true
    var handler: (@MainActor () -> Void)?
    func brightness() -> Double? { 0.8 }
    func observe(_ handler: @escaping @MainActor () -> Void) -> Bool { self.handler = handler; return true }
    func stopObserving() { handler = nil }
}

@MainActor
final class HUDFeatureTests {
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        suite = "app.notch.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func make() -> (HUDFeature, FakeSystemShell, FakeVolumeSource, FakeBrightnessSource, RecordingPresenter) {
        let shell = FakeSystemShell()
        let volume = FakeVolumeSource()
        let brightness = FakeBrightnessSource()
        let feature = HUDFeature(
            defaults: defaults,
            shell: shell,
            clock: ManualClock(),
            volumeSource: { volume },
            brightnessSource: { brightness }
        )
        return (feature, shell, volume, brightness, RecordingPresenter())
    }

    @Test func activateStartsTheMonitorsAndSuppressesTheSystemHUD() async {
        let (feature, shell, volume, brightness, presenter) = make()
        feature.activate(presenter: presenter)
        await feature.settle()

        #expect(feature.model != nil)
        #expect(volume.handlers.count == 1)
        #expect(brightness.handler != nil)
        #expect(shell.steps == [.setBannersPreference(false), .restartControlCenter, .kickstartOSDUIHelper, .stopOSDUIHelper])
        #expect(presenter.presented.isEmpty)   // baselines never present
    }

    @Test func readingsReachTheIsland() async {
        let (feature, _, volume, _, presenter) = make()
        feature.activate(presenter: presenter)
        await feature.settle()

        volume.level = 0.9
        volume.fire()
        #expect(presenter.presented.count == 1)
        #expect(presenter.presented.first?.featureID == HUDViewModel.featureID)
    }

    @Test func deactivateStopsEverythingAndRestoresTheSystemHUD() async {
        let (feature, shell, volume, brightness, presenter) = make()
        feature.activate(presenter: presenter)
        await feature.settle()
        shell.clearSteps()

        feature.deactivate()
        await feature.settle()

        #expect(feature.model == nil)
        #expect(volume.handlers.isEmpty)
        #expect(brightness.handler == nil)
        #expect(shell.steps == [.kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter])
    }

    @Test func turningBothKindsOffLiftsAndTurningOneBackOnReapplies() async {
        let (feature, shell, volume, brightness, presenter) = make()
        feature.activate(presenter: presenter)
        await feature.settle()
        shell.clearSteps()

        feature.setVolume(false)
        await feature.settle()
        #expect(volume.handlers.isEmpty)
        #expect(brightness.handler != nil)
        // Still one kind on: suppression stays (the preference is already false, so only
        // the helper is re-stopped).
        #expect(shell.steps == [.kickstartOSDUIHelper, .stopOSDUIHelper])
        shell.clearSteps()

        feature.setBrightness(false)
        await feature.settle()
        #expect(brightness.handler == nil)
        #expect(shell.steps == [.kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter])
        shell.clearSteps()

        feature.setBrightness(true)
        await feature.settle()
        #expect(brightness.handler != nil)
        #expect(volume.handlers.isEmpty)
        #expect(shell.steps == [.setBannersPreference(false), .restartControlCenter, .kickstartOSDUIHelper, .stopOSDUIHelper])
    }

    @Test func repairAfterUncleanExitLiftsWhenTheFeatureIsOff() async {
        let (first, _, _, _, presenter) = make()
        first.activate(presenter: presenter)
        await first.settle()

        let (second, shell, _, _, _) = make()
        await second.repairAfterUncleanExit(featureEnabled: false)
        #expect(shell.steps == [.kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter])
    }

    @Test func activateAfterACrashRepairAppliesWithoutLiftingFirst() async {
        let (first, _, _, _, presenter) = make()
        first.activate(presenter: presenter)
        await first.settle()
        // The flags stay in the shared defaults, as they would after a crash.

        let (second, shell, _, _, secondPresenter) = make()
        shell.preference = false   // Control Center is already set the way the apply wants it
        await second.repairAfterUncleanExit(featureEnabled: true)
        second.activate(presenter: secondPresenter)
        await second.settle()

        #expect(shell.steps == [.kickstartOSDUIHelper, .stopOSDUIHelper])
    }

    @Test func deactivateWithoutAnActivateTouchesNothing() async {
        let (feature, shell, _, _, _) = make()
        feature.deactivate()
        await feature.settle()
        #expect(shell.steps.isEmpty)
    }

    @Test func prepareForTerminationLiftsSynchronously() async {
        let (feature, shell, _, _, presenter) = make()
        feature.activate(presenter: presenter)
        await feature.settle()
        shell.clearSteps()

        feature.prepareForTermination()
        #expect(shell.steps == [.kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter])
    }
}
