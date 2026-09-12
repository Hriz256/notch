import IslandCore
import Testing
@testable import DropZonesFeature

@Suite @MainActor struct DropZonesFeatureTests {

    @Test func registersUnderTheDropZonesFeatureID() {
        // The id is the registry key the status-menu toggle and the settings
        // keys are named after; later tasks build on this exact string.
        #expect(DropZonesFeature().id == FeatureID("dropzones"))
    }

    @Test func deactivatingBeforeActivatingIsHarmless() {
        // `FeatureRegistry` calls `deactivate` whenever the master switch goes
        // off, including for a feature that was never activated.
        let feature = DropZonesFeature()
        feature.deactivate()
        #expect(feature.id == FeatureID("dropzones"))
    }
}
