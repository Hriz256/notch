import Testing
import SwiftUI
@testable import IslandCore

@MainActor
struct IslandLayoutTests {
    let geometry = NotchGeometry(metrics: ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        safeAreaTop: 38,
        auxiliaryTopLeft: CGRect(x: 0, y: 1079, width: 764, height: 38),
        auxiliaryTopRight: CGRect(x: 964, y: 1079, width: 764, height: 38)
    ))!

    private func presentation(size: CGSize = CGSize(width: 390, height: 200)) -> Presentation {
        Presentation(featureID: FeatureID("music"), priority: .background, style: .peek,
                     leading: AnyView(EmptyView()), trailing: AnyView(EmptyView()),
                     expanded: AnyView(EmptyView()), expandedSize: size)
    }

    @Test func collapsedMatchesNotch() {
        let l = IslandLayout.resolve(state: .collapsed, current: nil, geometry: geometry)
        #expect(l.mode == .collapsed)
        #expect(l.size == CGSize(width: 200, height: 38))
        #expect(l.bottomRadius == 10)
    }

    @Test func peekWidensBySlotOnEachSide() {
        let p = presentation()
        let l = IslandLayout.resolve(state: .peek(p.id), current: p, geometry: geometry)
        #expect(l.mode == .peek)
        #expect(l.size == CGSize(width: 200 + 2 * IslandLayout.peekSlotWidth, height: 38))
        #expect(l.bottomRadius == 14)
    }

    @Test func expandedUsesPresentationSizeButNeverNarrowerThanNotch() {
        let p = presentation(size: CGSize(width: 120, height: 200))
        let l = IslandLayout.resolve(state: .expanded(p.id), current: p, geometry: geometry)
        #expect(l.mode == .expanded)
        #expect(l.size.width == 200 + 2 * IslandLayout.peekSlotWidth)
        #expect(l.size.height == 200)
        #expect(l.bottomRadius == 24)
    }

    @Test func expandedWithoutPresentationFallsBackToCollapsed() {
        let l = IslandLayout.resolve(state: .expanded(PresentationID()), current: nil, geometry: geometry)
        #expect(l.mode == .collapsed)
    }
}
