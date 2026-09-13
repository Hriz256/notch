import Foundation
import HUDShared
import Observation

/// User preferences for the HUD, backed by `UserDefaults`.
///
/// Same shape as `DropZonesSettings`: observable in-memory mirrors with write-through
/// setters, so the status menu re-renders on change and nothing is lost on a crash.
/// Keys (spec §2): `hud.volume`, `hud.brightness`.
@MainActor
@Observable
public final class HUDSettings {
    public static let volumeKey = "hud.volume"
    public static let brightnessKey = "hud.brightness"

    @ObservationIgnored private let defaults: UserDefaults
    private var volumeValue: Bool
    private var brightnessValue: Bool

    /// - Parameter defaults: injected so tests get a throw-away suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        volumeValue = defaults.object(forKey: Self.volumeKey) as? Bool ?? true
        brightnessValue = defaults.object(forKey: Self.brightnessKey) as? Bool ?? true
    }

    /// Whether volume changes show a HUD (default on).
    public var volume: Bool {
        get { volumeValue }
        set {
            volumeValue = newValue
            defaults.set(newValue, forKey: Self.volumeKey)
        }
    }

    /// Whether brightness changes show a HUD (default on).
    public var brightness: Bool {
        get { brightnessValue }
        set {
            brightnessValue = newValue
            defaults.set(newValue, forKey: Self.brightnessKey)
        }
    }

    /// With both off there is nothing to monitor and no reason to suppress the system HUD.
    public var isAnyKindOn: Bool { volume || brightness }

    public func isOn(_ kind: HUDKind) -> Bool {
        switch kind {
        case .volume: volume
        case .brightness: brightness
        }
    }
}
