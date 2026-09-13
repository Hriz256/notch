import AudioToolbox
import CoreAudio
import Foundation
import IslandCore

/// The real `VolumeDeviceSource`: HAL property listeners on the main queue.
///
/// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` is the same "main volume" the
/// menu-bar slider moves, whatever the device's channel layout; devices without it are
/// reported as `nil` and get no HUD. Mute is optional per device.
@MainActor
public final class CoreAudioVolumeSource: VolumeDeviceSource {
    public init() {}

    private static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    public func defaultOutputDevice() -> UInt32? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.defaultDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    public func sample(of device: UInt32) -> VolumeSample? {
        var volumeAddress = Self.volumeAddress
        guard AudioObjectHasProperty(device, &volumeAddress) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else {
            return nil
        }

        var muteAddress = Self.muteAddress
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let isMuted = AudioObjectHasProperty(device, &muteAddress)
            && AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted) == noErr
            && muted != 0
        return VolumeSample(level: Double(volume), isMuted: isMuted)
    }

    public func observeDefaultDevice(_ handler: @escaping @MainActor () -> Void) -> ScheduledToken {
        listen(AudioObjectID(kAudioObjectSystemObject), Self.defaultDeviceAddress, handler)
    }

    public func observeVolume(of device: UInt32, _ handler: @escaping @MainActor () -> Void) -> ScheduledToken {
        var tokens = [listen(device, Self.volumeAddress, handler)]
        var muteAddress = Self.muteAddress
        if AudioObjectHasProperty(device, &muteAddress) {
            tokens.append(listen(device, Self.muteAddress, handler))
        }
        return ScheduledToken { for token in tokens { token.cancel() } }
    }

    /// One listener block, delivered on the main queue and removed by the token. The block
    /// is kept so the removal passes the same object the HAL registered.
    private func listen(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ handler: @escaping @MainActor () -> Void
    ) -> ScheduledToken {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        return ScheduledToken {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
    }
}
