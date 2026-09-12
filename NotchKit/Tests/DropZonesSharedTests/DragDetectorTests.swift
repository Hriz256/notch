import CoreGraphics
import Testing
@testable import DropZonesShared

/// The detector is the whole drag grammar the global monitors feed, so these tests are
/// the only place it is exercised: the observer above it is pure AppKit plumbing.
@Suite struct DragDetectorTests {

    /// A generous rect away from the origin, so "inside" and "outside" points are
    /// unambiguous. The real one is the notch's hot rect in screen coordinates.
    private static let hotRect = CGRect(x: 100, y: 100, width: 300, height: 220)
    private static let inside = CGPoint(x: 250, y: 200)
    private static let outside = CGPoint(x: 10, y: 10)

    private func detector() -> DragDetector { DragDetector(hotRect: Self.hotRect) }

    /// A dragged event that satisfies the content test: a change count that differs from
    /// the mouse-down snapshot, plus files on the pasteboard.
    private func dragged(_ location: CGPoint, changeCount: Int = 8, hasFiles: Bool = true) -> DragDetector.Event {
        .dragged(changeCount: changeCount, hasFiles: hasFiles, location: location)
    }

    // MARK: - Idle

    @Test func aFreshDetectorIsIdle() {
        #expect(detector().phase == .idle)
    }

    @Test func eventsOtherThanMouseDownAreIgnoredWhileIdle() {
        var d = detector()
        #expect(d.receive(dragged(Self.inside)) == .none)
        #expect(d.phase == .idle)
        #expect(d.receive(.flagsChanged) == .none)
        #expect(d.phase == .idle)
        #expect(d.receive(.mouseUp) == .none)
        #expect(d.phase == .idle)
    }

    @Test func mouseDownEntersMouseDownWithoutOutput() {
        var d = detector()
        #expect(d.receive(.mouseDown(changeCount: 7)) == .none)
        #expect(d.phase == .mouseDown)
    }

    // MARK: - Promotion to dragging

    /// The pasteboard is often filled a few events after the mouse goes down, so the
    /// content test repeats on every dragged event instead of deciding once.
    @Test func aLatePasteboardFillPromotesOnTheLaterEvent() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        // Same change count: the drag has not published anything yet.
        #expect(d.receive(dragged(Self.outside, changeCount: 7)) == .none)
        #expect(d.phase == .mouseDown)
        // New count with files, but still outside the hot rect: promoted, silently.
        #expect(d.receive(dragged(Self.outside, changeCount: 8)) == .none)
        #expect(d.phase == .dragging(inHotRect: false))
    }

    @Test func aDragWithoutFilesNeverPromotes() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        for _ in 0..<5 {
            #expect(d.receive(dragged(Self.inside, changeCount: 8, hasFiles: false)) == .none)
            #expect(d.phase == .mouseDown)
        }
    }

    /// Promotion decides containment from the very event that promoted, so a drag that
    /// becomes recognisable while already over the notch opens the zones at once.
    @Test func promotingInsideTheHotRectEntersImmediately() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        #expect(d.receive(dragged(Self.inside)) == .enteredHotRect)
        #expect(d.phase == .dragging(inHotRect: true))
    }

    // MARK: - Crossing the hot rect

    @Test func enterAndLeaveEmitOncePerCrossing() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        _ = d.receive(dragged(Self.outside))
        #expect(d.receive(dragged(Self.inside)) == .enteredHotRect)
        // Moving around inside changes nothing.
        #expect(d.receive(dragged(CGPoint(x: 260, y: 210))) == .none)
        #expect(d.phase == .dragging(inHotRect: true))
        #expect(d.receive(dragged(Self.outside)) == .leftHotRect)
        #expect(d.receive(dragged(CGPoint(x: 20, y: 20))) == .none)
        #expect(d.phase == .dragging(inHotRect: false))
        // And a re-entry fires again.
        #expect(d.receive(dragged(Self.inside)) == .enteredHotRect)
    }

    @Test func theRectIncludesItsOwnEdge() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        _ = d.receive(dragged(Self.outside))
        #expect(d.receive(dragged(CGPoint(x: 100, y: 100))) == .enteredHotRect)
    }

    /// No notch screen: the rect is empty and the zones must never open.
    @Test func anEmptyHotRectNeverEntersOrLeaves() {
        var d = DragDetector(hotRect: .zero)
        _ = d.receive(.mouseDown(changeCount: 7))
        #expect(d.receive(dragged(.zero)) == .none)
        #expect(d.receive(dragged(Self.inside)) == .none)
        #expect(d.phase == .dragging(inHotRect: false))
        #expect(d.receive(.mouseUp) == .ended)
    }

    // MARK: - Mouse up

    @Test func mouseUpInsideTheRectEndsTheDrag() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        #expect(d.receive(dragged(Self.inside)) == .enteredHotRect)
        #expect(d.receive(.mouseUp) == .ended)
        #expect(d.phase == .idle)
    }

    /// The consumer knows whether zones were open, so the end is reported the same way
    /// wherever the cursor was.
    @Test func mouseUpOutsideTheRectAlsoEndsTheDrag() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        _ = d.receive(dragged(Self.outside))
        #expect(d.receive(.mouseUp) == .ended)
        #expect(d.phase == .idle)
    }

    /// A plain click that never became a drag has nothing to end.
    @Test func mouseUpWithoutAPromotionIsSilent() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        #expect(d.receive(.mouseUp) == .none)
        #expect(d.phase == .idle)
    }

    // MARK: - Modifier keys

    @Test func flagsChangedWhileDraggingCancels() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        #expect(d.receive(dragged(Self.inside)) == .enteredHotRect)
        #expect(d.receive(.flagsChanged) == .cancelled)
        #expect(d.phase == .cancelled)
    }

    @Test func draggedEventsAreIgnoredAfterACancel() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        _ = d.receive(dragged(Self.outside))
        _ = d.receive(.flagsChanged)
        #expect(d.receive(dragged(Self.inside)) == .none)
        #expect(d.receive(.flagsChanged) == .none)
        #expect(d.phase == .cancelled)
    }

    /// The cancel already told the consumer to close; the mouse-up must not tell it again.
    @Test func mouseUpAfterACancelIsSilentAndReturnsToIdle() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        _ = d.receive(dragged(Self.inside))
        _ = d.receive(.flagsChanged)
        #expect(d.receive(.mouseUp) == .none)
        #expect(d.phase == .idle)
    }

    @Test func flagsChangedBeforeAPromotionIsHarmless() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        #expect(d.receive(.flagsChanged) == .none)
        #expect(d.phase == .mouseDown)
        // The drag can still start: a modifier held from the beginning is not a cancel.
        #expect(d.receive(dragged(Self.inside)) == .enteredHotRect)
    }

    // MARK: - Re-entry through mouse-down

    /// Monitors can miss a mouse-up (another app grabbing the event, a drag ending in a
    /// space switch), so a new mouse-down always restarts from a fresh snapshot.
    @Test func mouseDownTwiceReSnapshotsTheChangeCount() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        #expect(d.receive(dragged(Self.inside, changeCount: 8)) == .enteredHotRect)
        // Second press snapshots 8, so a dragged event still at 8 cannot promote.
        #expect(d.receive(.mouseDown(changeCount: 8)) == .none)
        #expect(d.phase == .mouseDown)
        #expect(d.receive(dragged(Self.inside, changeCount: 8)) == .none)
        #expect(d.phase == .mouseDown)
        #expect(d.receive(dragged(Self.inside, changeCount: 9)) == .enteredHotRect)
    }

    @Test func mouseDownRecoversFromACancelledDrag() {
        var d = detector()
        _ = d.receive(.mouseDown(changeCount: 7))
        _ = d.receive(dragged(Self.inside))
        _ = d.receive(.flagsChanged)
        #expect(d.receive(.mouseDown(changeCount: 8)) == .none)
        #expect(d.phase == .mouseDown)
        #expect(d.receive(dragged(Self.inside, changeCount: 9)) == .enteredHotRect)
    }
}
