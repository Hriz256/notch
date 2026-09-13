import Foundation
import HUDShared
import IslandCore
import os

/// The default output device's level and mute state.
public struct VolumeSample: Equatable, Sendable {
    public var level: Double
    public var isMuted: Bool

    public init(level: Double, isMuted: Bool) {
        self.level = level
        self.isMuted = isMuted
    }
}

/// What the monitor needs from CoreAudio, behind a protocol so tests use a fake.
/// Devices are plain `UInt32`s (`AudioDeviceID`) so the protocol needs no CoreAudio import.
@MainActor
public protocol VolumeDeviceSource: AnyObject {
    func defaultOutputDevice() -> UInt32?
    /// `nil` when the device has no settable main volume (HDMI, DisplayPort).
    func sample(of device: UInt32) -> VolumeSample?
    /// Calls `handler` on the main actor whenever the default output device changes.
    func observeDefaultDevice(_ handler: @escaping @MainActor () -> Void) -> ScheduledToken
    /// Calls `handler` on the main actor whenever the device's volume or mute changes.
    func observeVolume(of device: UInt32, _ handler: @escaping @MainActor () -> Void) -> ScheduledToken
}

/// Follows the default output device and reports its level (spec §2 "Volume source").
///
/// `onReading`'s second argument is `initial`: the level at attach time — at start and
/// after every device switch — which the view model records as a baseline and never shows.
@MainActor
public final class VolumeMonitor {
    public var onReading: (HUDReading, Bool) -> Void = { _, _ in }

    private let source: any VolumeDeviceSource
    private let logger = Logger(subsystem: "app.notch", category: "hud.volume")
    private var defaultToken: ScheduledToken?
    private var volumeToken: ScheduledToken?
    private var device: UInt32?
    private var isStopped = false

    public init(source: any VolumeDeviceSource) {
        self.source = source
    }

    public func start() {
        isStopped = false
        defaultToken?.cancel()
        defaultToken = source.observeDefaultDevice { [weak self] in self?.attach() }
        attach()
    }

    public func stop() {
        isStopped = true
        defaultToken?.cancel()
        defaultToken = nil
        volumeToken?.cancel()
        volumeToken = nil
        device = nil
    }

    // MARK: - Private

    /// Follows the current default device: drops the old listener, installs one on the new
    /// device and reports its level as a baseline.
    private func attach() {
        guard !isStopped else { return }
        volumeToken?.cancel()
        volumeToken = nil
        device = source.defaultOutputDevice()
        guard let device else {
            logger.info("no default output device")
            return
        }
        guard let sample = source.sample(of: device) else {
            logger.info("the default output device has no volume control; no volume HUD")
            return
        }
        volumeToken = source.observeVolume(of: device) { [weak self] in self?.volumeChanged() }
        onReading(Self.reading(sample), true)
    }

    private func volumeChanged() {
        guard !isStopped, let device, let sample = source.sample(of: device) else { return }
        onReading(Self.reading(sample), false)
    }

    private static func reading(_ sample: VolumeSample) -> HUDReading {
        HUDReading(kind: .volume, level: sample.level, isMuted: sample.isMuted)
    }
}
