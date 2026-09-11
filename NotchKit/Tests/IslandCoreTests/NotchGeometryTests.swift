import Testing
import CoreGraphics
@testable import IslandCore

struct NotchGeometryTests {
    // MacBook Pro 16" (2024+): 1728x1117 points, menu bar/notch 38 pt, notch ~ 200 pt wide.
    let metrics = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        safeAreaTop: 38,
        auxiliaryTopLeft: CGRect(x: 0, y: 1079, width: 764, height: 38),
        auxiliaryTopRight: CGRect(x: 964, y: 1079, width: 764, height: 38)
    )

    @Test func computesNotchRectFromAuxiliaryAreas() throws {
        let g = try #require(NotchGeometry(metrics: metrics))
        #expect(g.notchWidth == 200)
        #expect(g.notchHeight == 38)
        #expect(g.notchRect == CGRect(x: 764, y: 1079, width: 200, height: 38))
    }

    @Test func noNotchReturnsNil() {
        let flat = ScreenMetrics(frame: metrics.frame, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        #expect(NotchGeometry(metrics: flat) == nil)
    }

    @Test func zeroSafeAreaWithAuxAreasReturnsNil() {
        let odd = ScreenMetrics(frame: metrics.frame, safeAreaTop: 0,
                                auxiliaryTopLeft: metrics.auxiliaryTopLeft, auxiliaryTopRight: metrics.auxiliaryTopRight)
        #expect(NotchGeometry(metrics: odd) == nil)
    }
}
