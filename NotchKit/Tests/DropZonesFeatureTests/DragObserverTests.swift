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

/// `start()`/`stop()` — what the monitors *cost*, rather than what they see.
///
/// A real drag is out of reach for a test, but the bookkeeping around the
/// monitors is not, and it is where the expensive mistakes live: monitors left
/// installed for the life of the process, or installed twice so every event is
/// handled sixteen times.
///
/// A private pasteboard throughout: a test must never touch the real `.drag`
/// pasteboard, which belongs to whatever the user is dragging right now.
@MainActor @Suite struct DragObserverLifecycleTests {

    /// AppKit wants its shared application before `NSEvent` monitors are installed.
    private static let application: NSApplication = .shared

    private func makeObserver() -> DragObserver {
        _ = Self.application
        return DragObserver(
            hotRect: { CGRect(x: 0, y: 0, width: 300, height: 121) },
            pasteboard: NSPasteboard(name: .init("app.notch.tests.\(UUID().uuidString)"))
        )
    }

    @Test func startInstallsEightMonitorsAndStopRemovesThemAll() {
        let observer = makeObserver()
        #expect(observer.monitorCount == 0)

        observer.start()

        // Four masks × (global + local). A refused global monitor (`.flagsChanged`
        // without Accessibility trust) returns nil and is dropped, so this is also
        // the assertion that no permission is needed for any of them.
        #expect(observer.monitorCount == 8)

        observer.stop()

        #expect(observer.monitorCount == 0)
    }

    @Test func startIsIdempotentAndTheCycleCanBeRepeated() {
        let observer = makeObserver()

        observer.start()
        observer.start()
        #expect(observer.monitorCount == 8, "a second start must not double-register")

        observer.stop()
        observer.stop()
        #expect(observer.monitorCount == 0, "stop is safe to call twice")

        observer.start()
        #expect(observer.monitorCount == 8)
        observer.stop()
        #expect(observer.monitorCount == 0)
    }

    @Test func stopClearsTheDragOutFlag() {
        // `StashDragSource` sets this for the life of one drag out of the stash.
        // Latched `true` across a stop it would hide every zone but the stash for
        // the rest of the session.
        let observer = makeObserver()
        observer.start()
        observer.isDragOutActive = true

        observer.stop()

        #expect(!observer.isDragOutActive)
    }

    @Test func anObserverThatIsDroppedTakesItsMonitorsWithIt() {
        // `NSEvent` owns the monitors with no reference back to us, so a dropped
        // observer would otherwise leave eight handlers running for the session.
        // All this can assert is that the isolated `deinit` runs without tripping
        // the concurrency checks — and that the process survives it.
        do {
            let observer = makeObserver()
            observer.start()
            #expect(observer.monitorCount == 8)
        }
    }
}
