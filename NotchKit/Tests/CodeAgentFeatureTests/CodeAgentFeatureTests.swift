import Testing
import Foundation
import IslandCore
import CodeAgentShared
@testable import CodeAgentFeature

@Suite @MainActor struct CodeAgentFeatureTests {
    @Test func usesCodeFeatureID() {
        #expect(CodeAgentFeature().id == FeatureID("code"))
    }
}
