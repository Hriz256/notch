import DropZonesShared
import Foundation
import IslandCore
import SwiftUI
import Testing
@testable import DropZonesFeature

/// Records presentations without drawing anything; the feature's tests only need to know
/// that a view model was built around it.
@MainActor
private final class FakePresenter: IslandPresenting {
    var presented: [Presentation] = []

    func present(_ presentation: Presentation) { presented.append(presentation) }
    func update(_ presentation: Presentation) {}
    func dismiss(_ id: PresentationID) {}
}

/// A feature pointed at a throw-away stash directory and a throw-away defaults suite, so
/// no test can reach the user's real stash or preferences.
@MainActor
private func makeFeature() -> (DropZonesFeature, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dropzones-feature-tests/\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "dropzones.feature.tests.\(UUID().uuidString)")!
    return (DropZonesFeature(baseDirectory: directory, defaults: defaults), directory)
}

@Suite @MainActor struct DropZonesFeatureTests {

    @Test func registersUnderTheDropZonesFeatureID() {
        // The id is the registry key the status-menu toggle and the settings
        // keys are named after; later tasks build on this exact string.
        #expect(DropZonesFeature().id == FeatureID("dropzones"))
        #expect(DropZonesFeature.featureID == DropZonesViewModel.featureID)
    }

    @Test func deactivatingBeforeActivatingIsHarmless() {
        // `FeatureRegistry` calls `deactivate` whenever the master switch goes
        // off, including for a feature that was never activated.
        let (feature, _) = makeFeature()
        feature.deactivate()
        feature.deactivate()
        #expect(feature.model == nil)
        #expect(feature.id == FeatureID("dropzones"))
    }

    @Test func activatingBuildsAModelAroundTheFeaturesOwnSettings() {
        let (feature, _) = makeFeature()
        defer { feature.deactivate() }

        feature.activate(presenter: FakePresenter())

        let model = try? #require(feature.model)
        // One settings object, or the status menu and the island's own menu would disagree.
        #expect(model?.settings === feature.settings)
        // The observer is handed to the model so a drag out of the stash can be recognised.
        #expect(model?.dragObserver != nil)
        // Without a provider the catcher would never be ordered in.
        #expect(model?.panelFrameProvider != nil)
    }

    @Test func deactivatingDropsTheModelAndActivatingAgainBuildsAFreshOne() {
        let (feature, _) = makeFeature()
        let presenter = FakePresenter()

        feature.activate(presenter: presenter)
        let first = try? #require(feature.model)

        feature.deactivate()
        #expect(feature.model == nil)

        feature.activate(presenter: presenter)
        defer { feature.deactivate() }
        #expect(feature.model != nil)
        #expect(feature.model !== first)
        // Settings outlive the island: they are read by the menu whether it is on or off.
        #expect(feature.model?.settings === feature.settings)
    }

    // MARK: - Panel geometry

    @Test func panelFrameIsTheCentredPanelRectAtTheTopOfTheScreen() {
        // The 14" reference machine: 1728×1117 points, notch 185 wide starting at x 771.
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let notch = CGRect(x: 771, y: 1117 - 32, width: 185, height: 32)

        let frame = DropZonesFeature.panelFrame(screenFrame: screen, notchRect: notch)

        #expect(frame.origin.x == 723.5)
        #expect(frame.origin.y == 977)
        #expect(frame.size == DropZonesViewModel.zonesSize)
        // Centred on the notch, which is what makes the catcher line up with the cards even
        // though `IslandLayout` floors the black shape at the wider peek width.
        #expect(frame.midX == notch.midX)
        #expect(frame.maxY == screen.maxY)
    }

    @Test func panelFrameFollowsTheScreenTheNotchIsOn() {
        // A second display placed to the right of the built-in one: the panel is expected
        // in that screen's coordinates, not at an origin-relative offset.
        let screen = CGRect(x: 1728, y: 200, width: 1512, height: 982)
        let notch = CGRect(x: 1728 + 663, y: screen.maxY - 32, width: 186, height: 32)

        let frame = DropZonesFeature.panelFrame(screenFrame: screen, notchRect: notch)

        #expect(frame.midX == notch.midX)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.size == DropZonesViewModel.zonesSize)
    }

    // MARK: - The status-menu surface

    @Test func menuSettersWriteThroughWhileTheFeatureIsOff() {
        let (feature, _) = makeFeature()

        feature.setAirDropZone(false)
        feature.setStashZone(false)
        feature.setSecondZone(true)
        feature.setStashDropAction(.add)

        #expect(feature.settings.airdrop == false)
        #expect(feature.settings.stash == false)
        #expect(feature.settings.secondZone == true)
        #expect(feature.settings.stashDropAction == .add)
        // Nothing to clear or reveal without a model, which is what greys those rows out.
        #expect(feature.stashIsEmpty)
    }

    @Test func menuSettersGoThroughTheViewModelWhileTheFeatureIsOn() {
        let (feature, _) = makeFeature()
        defer { feature.deactivate() }
        feature.activate(presenter: FakePresenter())

        feature.setAirDropZone(false)
        feature.setSecondZone(true)
        feature.setStashDropAction(.add)

        // The model reads the same object, so the panel it would draw next is already right.
        #expect(feature.model?.settings.airdrop == false)
        #expect(feature.model?.settings.secondZone == true)
        #expect(feature.model?.settings.stashDropAction == .add)

        // Setting a value to what it already is must not flip it (the model only toggles).
        feature.setAirDropZone(false)
        #expect(feature.settings.airdrop == false)
    }
}
