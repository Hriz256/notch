import DropZonesShared
import Foundation
import Testing
@testable import DropZonesFeature

/// A throw-away `UserDefaults` suite per test: the settings write through on every
/// setter, and the real `standard` domain is not ours to scribble on.
@MainActor
final class DropZonesSettingsTests {
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        suite = "app.notch.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test func defaultsFollowTheSpec() {
        let settings = DropZonesSettings(defaults: defaults)

        #expect(settings.airdrop)
        #expect(settings.stash)
        #expect(!settings.secondZone)
        #expect(settings.stashDropAction == .add)
    }

    @Test func writesUseTheSpecKeys() {
        let settings = DropZonesSettings(defaults: defaults)

        settings.airdrop = false
        settings.stash = false
        settings.secondZone = true
        settings.stashDropAction = .add

        #expect(defaults.bool(forKey: "dropzones.airdrop") == false)
        #expect(defaults.bool(forKey: "dropzones.stash") == false)
        #expect(defaults.bool(forKey: "dropzones.secondZone") == true)
        #expect(defaults.string(forKey: "dropzones.stashDropAction") == "add")
    }

    @Test func storedValuesAreReadBack() {
        defaults.set(false, forKey: "dropzones.airdrop")
        defaults.set(true, forKey: "dropzones.secondZone")
        defaults.set("add", forKey: "dropzones.stashDropAction")

        let settings = DropZonesSettings(defaults: defaults)

        #expect(!settings.airdrop)
        #expect(settings.stash)  // untouched, still the default
        #expect(settings.secondZone)
        #expect(settings.stashDropAction == .add)
    }

    @Test func anUnreadableDropActionFallsBackToTheDefault() {
        defaults.set("nonsense", forKey: "dropzones.stashDropAction")

        #expect(DropZonesSettings(defaults: defaults).stashDropAction == .add)
    }

    @Test func valuesSurviveANewInstance() {
        let settings = DropZonesSettings(defaults: defaults)
        settings.stash = false
        settings.stashDropAction = .add

        let reloaded = DropZonesSettings(defaults: defaults)

        #expect(!reloaded.stash)
        #expect(reloaded.stashDropAction == .add)
    }

    /// The zone policy reads the four settings through `ZoneState`; this is the one
    /// place the two halves meet, so it is worth pinning the wiring down.
    @Test func theZoneStateBuiltFromTheDefaultsOffersAirDropAndTheStash() {
        let settings = DropZonesSettings(defaults: defaults)
        let state = ZoneState(
            airdrop: settings.airdrop,
            stash: settings.stash,
            secondZone: settings.secondZone,
            stashDropAction: settings.stashDropAction
        )

        #expect(state.zones() == [.airDrop, .stash])
    }
}
