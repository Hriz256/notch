import Testing
@testable import HUDShared

struct SuppressionPlanTests {
    @Test func applySetsThePreferenceRestartsControlCenterThenStopsTheHelper() {
        #expect(SuppressionPlan.apply(controlCenterConfigured: false) == [
            .setBannersPreference(false), .restartControlCenter, .kickstartOSDUIHelper, .stopOSDUIHelper,
        ])
    }

    @Test func applyWithControlCenterAlreadyConfiguredSkipsIt() {
        #expect(SuppressionPlan.apply(controlCenterConfigured: true) == [.kickstartOSDUIHelper, .stopOSDUIHelper])
    }

    @Test func liftRelaunchesTheHelperAndRemovesOnlyOurPreference() {
        #expect(SuppressionPlan.lift(weSetPreference: true) == [
            .kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter,
        ])
        #expect(SuppressionPlan.lift(weSetPreference: false) == [.kickstartOSDUIHelper])
    }

    @Test func repairOnlyWhenTheHelperIsNotStopped() {
        #expect(SuppressionPlan.repairIfNeeded(osdHelperStopped: true) == [])
        #expect(SuppressionPlan.repairIfNeeded(osdHelperStopped: false) == [.kickstartOSDUIHelper, .stopOSDUIHelper])
    }
}
