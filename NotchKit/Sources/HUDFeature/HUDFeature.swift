import Foundation
import HUDShared
import IslandCore
import Observation
import os

/// The "HUD" island feature: the two monitors, the system-HUD suppressor and the view
/// model that turns readings into presentations (spec §3.2).
///
/// `settings` and the suppressor are built in `init`: the status menu reads and writes the
/// settings whether the feature is on or off, and the suppressor's crash repair runs before
/// the registry activates anything.
@MainActor
@Observable
public final class HUDFeature: IslandFeature {
    public static let featureID = HUDViewModel.featureID
    public let id = HUDViewModel.featureID

    /// User preferences, shared with the status menu.
    public let settings: HUDSettings
    /// The live view model, or `nil` while the feature is off.
    public private(set) var model: HUDViewModel?

    @ObservationIgnored let suppressor: SystemHUDSuppressor
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private let makeVolumeSource: @MainActor () -> any VolumeDeviceSource
    @ObservationIgnored private let makeBrightnessSource: @MainActor () -> any BrightnessSource
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "hud.feature")
    @ObservationIgnored private var volume: VolumeMonitor?
    @ObservationIgnored private var brightness: BrightnessMonitor?
    @ObservationIgnored private var suppressionTask: Task<Void, Never>?

    public init(
        defaults: UserDefaults = .standard,
        shell: any SystemShell = LiveSystemShell(),
        clock: any IslandClock = TaskClock(),
        volumeSource: @escaping @MainActor () -> any VolumeDeviceSource = { CoreAudioVolumeSource() },
        brightnessSource: @escaping @MainActor () -> any BrightnessSource = { DisplayServicesBrightnessSource() }
    ) {
        settings = HUDSettings(defaults: defaults)
        suppressor = SystemHUDSuppressor(shell: shell, clock: clock, defaults: defaults)
        self.clock = clock
        makeVolumeSource = volumeSource
        makeBrightnessSource = brightnessSource
    }

    // MARK: - Lifecycle

    /// Once per launch, before the registry registers this feature: a suppression left
    /// behind by a crash is lifted unless the feature is about to re-apply it anyway.
    public func repairAfterUncleanExit(featureEnabled: Bool) async {
        await suppressor.repairAtLaunch(featureWillBeOn: featureEnabled && settings.isAnyKindOn)
    }

    public func activate(presenter: any IslandPresenting) {
        deactivate()
        model = HUDViewModel(presenter: presenter, clock: clock, viewFactory: .live)
        startMonitors()
        syncSuppression()
        logger.info("HUD feature activated")
    }

    public func deactivate() {
        let wasActive = model != nil
        stopMonitors()
        model?.stop()
        model = nil
        // Nothing was active, so there is nothing of ours to undo: a `deactivate()` here
        // would lift a suppression this launch is about to re-apply (the leading call in
        // ``activate(presenter:)`` after a crash left the flags set).
        guard wasActive else { return }
        syncSuppression()
        logger.info("HUD feature deactivated")
    }

    /// For `applicationWillTerminate`: the system HUD is back before the process ends.
    public func prepareForTermination() {
        stopMonitors()
        suppressionTask?.cancel()
        suppressionTask = nil
        suppressor.liftSynchronously()
    }

    /// Test hook: waits for the pending suppression operation.
    func settle() async {
        await suppressionTask?.value
        await suppressor.settle()
    }

    // MARK: - Status-menu surface

    public func setVolume(_ on: Bool) {
        guard settings.volume != on else { return }
        settings.volume = on
        kindsChanged()
    }

    public func setBrightness(_ on: Bool) {
        guard settings.brightness != on else { return }
        settings.brightness = on
        kindsChanged()
    }

    // MARK: - Private

    private func kindsChanged() {
        guard model != nil else { return }
        startMonitors()
        syncSuppression()
    }

    /// (Re)starts exactly the monitors the settings ask for.
    private func startMonitors() {
        stopMonitors()
        guard let model else { return }
        if settings.volume {
            let monitor = VolumeMonitor(source: makeVolumeSource())
            monitor.onReading = { [weak model] reading, initial in
                if initial { model?.baseline(reading) } else { model?.receive(reading) }
            }
            monitor.start()
            volume = monitor
        }
        if settings.brightness {
            let monitor = BrightnessMonitor(source: makeBrightnessSource())
            monitor.onReading = { [weak model] reading, initial in
                if initial { model?.baseline(reading) } else { model?.receive(reading) }
            }
            monitor.start()
            brightness = monitor
        }
    }

    private func stopMonitors() {
        volume?.stop()
        volume = nil
        brightness?.stop()
        brightness = nil
    }

    /// Suppression follows "on and at least one kind on"; the suppressor serialises the calls.
    private func syncSuppression() {
        let wanted = model != nil && settings.isAnyKindOn
        let suppressor = suppressor
        suppressionTask = Task { @MainActor in
            if wanted { await suppressor.apply() } else { await suppressor.lift() }
        }
    }
}
