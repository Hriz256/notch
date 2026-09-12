import AppKit
import Testing
@testable import DropZonesFeature

/// `DragObserver.hotRect(for:)` — the only part of the observer that can be
/// tested without a human at the trackpad. The monitors themselves are exercised
/// by hand (an agent cannot perform a real drag); the rect they gate on is pure
/// arithmetic and is where an off-by-one would quietly cost the user the feature.
@MainActor @Suite struct DragObserverHotRectTests {

    /// This machine's built-in display: 1728 × 1117 at the origin.
    private let builtIn = CGRect(x: 0, y: 0, width: 1_728, height: 1_117)

    @Test func theBuiltInScreenGetsSeamsRectClippedAndExtendedByOnePoint() {
        // Seam's rule is (midX − 150, maxY − 120, 300, 220): midX 864 → x 714,
        // maxY 1117 → y 997. The nominal rect reaches y 1217, a hundred points
        // above the glass, so clipping to the screen leaves 997…1117 (height 120).
        // Then one point is added on top — see the next test for why.
        let rect = DragObserver.hotRect(for: builtIn)

        #expect(rect == CGRect(x: 714, y: 997, width: 300, height: 121))
        #expect(rect.minX == 714)
        #expect(rect.maxX == 1_014)
        #expect(rect.minY == 997)
        #expect(rect.maxY == 1_118)
    }

    @Test func aCursorPinnedToTheTopEdgeOfTheScreenIsInside() {
        // The reason for the extra point: `CGRect.contains` is half-open, so a
        // rect ending exactly at the screen's maxY excludes the one row of
        // coordinates the cursor sits on when the user shoves it into the notch —
        // which is precisely the gesture the feature exists for.
        let rect = DragObserver.hotRect(for: builtIn)

        #expect(rect.contains(CGPoint(x: builtIn.midX, y: builtIn.maxY)))
        #expect(rect.contains(CGPoint(x: builtIn.midX, y: builtIn.maxY - 120)))
        #expect(!rect.contains(CGPoint(x: builtIn.midX, y: builtIn.maxY - 121)))
    }

    @Test func theRectIsCentredHorizontallyAndStopsAtTheCardWidth() {
        let rect = DragObserver.hotRect(for: builtIn)

        #expect(rect.midX == builtIn.midX)
        #expect(!rect.contains(CGPoint(x: 713.9, y: 1_000)))
        #expect(rect.contains(CGPoint(x: 714, y: 1_000)))
        #expect(!rect.contains(CGPoint(x: 1_014, y: 1_000)), "contains is half-open on maxX too")
    }

    @Test func aScreenWithAnOffsetOriginKeepsTheSameShape() {
        // An external display left of and above the built-in one: the numbers are
        // all relative to that screen's own frame, never to the global origin.
        let external = CGRect(x: -1_920, y: 200, width: 1_920, height: 1_080)

        let rect = DragObserver.hotRect(for: external)

        #expect(rect == CGRect(x: -1_110, y: 1_160, width: 300, height: 121))
        #expect(rect.contains(CGPoint(x: external.midX, y: external.maxY)))
    }

    @Test func aScreenNarrowerThanTheRectIsClippedToIt() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 200)

        let rect = DragObserver.hotRect(for: tiny)

        // 100 − 150 = −50 would put the rect off the left edge of the screen.
        #expect(rect == CGRect(x: 0, y: 80, width: 200, height: 121))
    }

    @Test func anEmptyScreenFrameGivesAnEmptyRect() {
        // "No notch screen / geometry unavailable" (design §4): the observer stays
        // installed and the zones simply never open, because an empty rect
        // contains nothing.
        #expect(DragObserver.hotRect(for: .zero).isEmpty)
        #expect(!DragObserver.hotRect(for: .zero).contains(CGPoint.zero))
    }
}
