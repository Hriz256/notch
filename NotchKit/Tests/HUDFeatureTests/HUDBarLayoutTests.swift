import CoreGraphics
import Testing
@testable import HUDFeature

struct HUDBarLayoutTests {
    @Test func barIsSixtyByFour() {
        #expect(HUDBarLayout.size == CGSize(width: 60, height: 4))
    }

    @Test func fillWidthIsTheFractionOfTheTrackClamped() {
        #expect(HUDBarLayout.fillWidth(fraction: 0.5, total: 60) == 30)
        #expect(HUDBarLayout.fillWidth(fraction: 0, total: 60) == 0)
        #expect(HUDBarLayout.fillWidth(fraction: 1.4, total: 60) == 60)
        #expect(HUDBarLayout.fillWidth(fraction: -1, total: 60) == 0)
    }
}
