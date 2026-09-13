import Foundation
import HUDShared
import Testing
@testable import HUDFeature

/// A throw-away `UserDefaults` suite per test; `standard` is not ours to scribble on.
@MainActor
final class HUDSettingsTests {
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        suite = "app.notch.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test func bothKindsAreOnByDefault() {
        let settings = HUDSettings(defaults: defaults)
        #expect(settings.volume)
        #expect(settings.brightness)
        #expect(settings.isAnyKindOn)
        #expect(settings.isOn(.volume))
        #expect(settings.isOn(.brightness))
    }

    @Test func writesUseTheSpecKeysAndPersist() throws {
        let settings = HUDSettings(defaults: defaults)
        settings.volume = false
        settings.brightness = false

        #expect(defaults.object(forKey: "hud.volume") as? Bool == false)
        #expect(defaults.object(forKey: "hud.brightness") as? Bool == false)
        #expect(!settings.isAnyKindOn)

        let reloaded = HUDSettings(defaults: defaults)
        #expect(!reloaded.volume)
        #expect(!reloaded.brightness)
    }
}
