import AppKit
import DropZonesShared
import Testing
@testable import DropZonesFeature

/// The catcher is the one window in the app whose *configuration* is the feature:
/// get a flag wrong and either nothing is dropped on it or it steals clicks from
/// the whole desktop. Every value below is quoted from the design's "Drop catcher"
/// row, so this suite is the regression net for that row.
@MainActor @Suite struct DropCatcherWindowTests {

    /// AppKit needs its shared application before any window is made, even in a
    /// test process that never runs an event loop.
    private static let application: NSApplication = .shared

    private func makeWindow() -> DropCatcherWindow {
        _ = Self.application
        return DropCatcherWindow()
    }

    // MARK: - Configuration

    @Test func itIsABorderlessNonActivatingPanel() {
        let window = makeWindow()

        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.styleMask.contains(.borderless))
        #expect(window.backingType == .buffered)
    }

    @Test func itIsCompletelyInvisible() {
        // The island draws the zones; this window only catches the drop. An alpha
        // of 0 still receives dragging messages (verified by the spike).
        let window = makeWindow()

        #expect(window.alphaValue == 0)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(!window.hasShadow)
    }

    @Test func itSitsOneLevelAboveTheIsland() {
        // Island = statusWindow + 1 (`SurfaceWindow`), catcher = statusWindow + 2.
        let window = makeWindow()

        #expect(window.level == NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2))
        #expect(window.level.rawValue == Int(CGWindowLevelForKey(.statusWindow)) + 2)
    }

    @Test func itJoinsEverySpaceAndStaysOutOfTheWay() {
        let window = makeWindow()

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.stationary))
        #expect(window.collectionBehavior.contains(.ignoresCycle))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func itNeverTakesFocus() {
        let window = makeWindow()

        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(!window.hidesOnDeactivate)
        #expect(!window.isReleasedWhenClosed)
    }

    @Test func itIgnoresMouseEventsUntilItIsShown() {
        // While no drag is in flight the catcher must be invisible to the mouse,
        // or a window covering the notch would eat every click in that strip.
        let window = makeWindow()

        #expect(window.ignoresMouseEvents)
        #expect(!window.isVisible)
    }

    @Test func theContentViewIsTheCatcherView() {
        let window = makeWindow()

        #expect(window.contentView === window.catcherView)
    }

    // MARK: - Registered types

    @Test func itRegistersFileURLsPromisesAndImageData() {
        let window = makeWindow()
        let registered = Set(window.catcherView.registeredDraggedTypes)

        #expect(registered.contains(.fileURL))
        #expect(registered.contains(.URL))
        #expect(registered.contains(.png))
        #expect(registered.contains(.tiff))
        for promise in NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:)) {
            #expect(registered.contains(promise), "\(promise.rawValue)")
        }
    }

    // MARK: - show / hide

    @Test func showPutsTheWindowUpAndLetsTheMouseIn() {
        let window = makeWindow()
        let frame = CGRect(x: 100, y: 200, width: 280, height: 140)

        window.show(frame: frame)

        #expect(window.isVisible)
        #expect(!window.ignoresMouseEvents)
        #expect(window.frame == frame)
    }

    @Test func hideTakesItDownAgain() {
        let window = makeWindow()
        window.show(frame: CGRect(x: 100, y: 200, width: 280, height: 140))

        window.hide()

        #expect(!window.isVisible)
        #expect(window.ignoresMouseEvents)
    }

    @Test func showCanMoveTheWindowWhileItIsUp() {
        // The panel's frame changes as the zones widen under the cursor; the
        // catcher follows it without being torn down.
        let window = makeWindow()
        window.show(frame: CGRect(x: 100, y: 200, width: 280, height: 140))

        window.show(frame: CGRect(x: 120, y: 200, width: 300, height: 140))

        #expect(window.frame == CGRect(x: 120, y: 200, width: 300, height: 140))
        #expect(window.isVisible)
        window.hide()
    }

    @Test func showDefaultsAnUnsetPanelFrameToItsOwn() {
        // Without this the view converts every drag against `.zero`: the hit test
        // lands hundreds of points away, no zone is ever under the cursor and the
        // drop is refused with nothing in the log to say why. The catcher's frame
        // always contains the panel, so it is the safe default.
        let window = makeWindow()
        let frame = CGRect(x: 700, y: 900, width: 320, height: 180)

        window.show(frame: frame)
        defer { window.hide() }

        #expect(window.catcherView.panelFrame == frame)
    }

    @Test func showLeavesAPanelFrameTheOwnerSetAlone() {
        // The real one is the *panel's* rect, which is smaller than the catcher's
        // and is what the zone layout is measured in; show() must never clobber it.
        let window = makeWindow()
        let panel = CGRect(x: 720, y: 940, width: 280, height: 140)
        window.catcherView.panelFrame = panel

        window.show(frame: CGRect(x: 700, y: 900, width: 320, height: 180))
        defer { window.hide() }

        #expect(window.catcherView.panelFrame == panel)
    }

    // MARK: - Coordinates

    @Test func screenPointsBecomePanelPointsWithTheOriginAtTheTopLeft() {
        // Screen coordinates grow upwards; `ZoneLayout` (and SwiftUI) count down
        // from the panel's top edge, so the y axis flips around `panelFrame.maxY`.
        let view = DropCatcherView(frame: .zero)
        view.panelFrame = CGRect(x: 700, y: 900, width: 280, height: 140)

        #expect(view.panelPoint(fromScreen: CGPoint(x: 700, y: 1_040)) == CGPoint(x: 0, y: 0))
        #expect(view.panelPoint(fromScreen: CGPoint(x: 980, y: 900)) == CGPoint(x: 280, y: 140))
        #expect(view.panelPoint(fromScreen: CGPoint(x: 840, y: 970)) == CGPoint(x: 140, y: 70))
        // A cursor above the panel reads negative rather than being clamped: the
        // delegate's hit test answers "no zone", which is the honest answer.
        #expect(view.panelPoint(fromScreen: CGPoint(x: 840, y: 1_100)) == CGPoint(x: 140, y: -60))
    }

    // MARK: - Dragging destination

    @Test func enteringOverAZoneOffersACopyAndReportsThePanelPoint() throws {
        let window = makeWindow()
        let frame = CGRect(x: 700, y: 900, width: 280, height: 140)
        window.show(frame: frame)
        defer { window.hide() }
        window.catcherView.panelFrame = frame

        let delegate = RecordingCatcherDelegate(zone: .stash)
        window.catcherView.delegate = delegate
        let info = FakeDraggingInfo()
        // Window coordinates, origin bottom-left: 140 points in, 70 points up →
        // the middle of the panel.
        info.draggingLocation = CGPoint(x: 140, y: 70)

        let entered = window.catcherView.draggingEntered(info)
        let updated = window.catcherView.draggingUpdated(info)

        #expect(entered == .copy)
        #expect(updated == .copy)
        #expect(delegate.targetedPoints == [CGPoint(x: 140, y: 70), CGPoint(x: 140, y: 70)])
    }

    @Test func enteringOverAGapRejectsTheDrag() {
        let window = makeWindow()
        window.show(frame: CGRect(x: 700, y: 900, width: 280, height: 140))
        defer { window.hide() }
        window.catcherView.panelFrame = window.frame

        let delegate = RecordingCatcherDelegate(zone: nil)
        window.catcherView.delegate = delegate
        let info = FakeDraggingInfo()

        #expect(window.catcherView.draggingEntered(info) == [])
        #expect(window.catcherView.draggingUpdated(info) == [])
    }

    @Test func exitingTellsTheDelegate() {
        let window = makeWindow()
        let delegate = RecordingCatcherDelegate(zone: .stash)
        window.catcherView.delegate = delegate

        window.catcherView.draggingExited(nil)

        #expect(delegate.exitCount == 1)
    }

    @Test func theDropIsAlwaysPreparedAndItsResultComesFromTheDelegate() {
        let window = makeWindow()
        window.show(frame: CGRect(x: 700, y: 900, width: 280, height: 140))
        defer { window.hide() }
        window.catcherView.panelFrame = window.frame

        let delegate = RecordingCatcherDelegate(zone: .airDrop)
        window.catcherView.delegate = delegate
        let info = FakeDraggingInfo()
        info.draggingLocation = CGPoint(x: 40, y: 100)

        #expect(window.catcherView.prepareForDragOperation(info))
        #expect(window.catcherView.performDragOperation(info))
        #expect(delegate.droppedPoints == [CGPoint(x: 40, y: 40)])

        delegate.acceptsDrop = false
        #expect(!window.catcherView.performDragOperation(info))
    }

    @Test func aDropWithNoDelegateIsRefused() {
        let window = makeWindow()

        #expect(!window.catcherView.performDragOperation(FakeDraggingInfo()))
    }

    @Test func aDragWithNoDelegateIsRefusedRatherThanAccepted() {
        // The window is ordered in before the feature attaches itself, and an
        // unowned catcher offering `.copy` would swallow drops into nothing.
        let window = makeWindow()
        let info = FakeDraggingInfo()

        #expect(window.catcherView.draggingEntered(info) == [])
        #expect(window.catcherView.draggingUpdated(info) == [])
    }

    @Test func itDoesNotAskForPeriodicUpdates() {
        // A timer while the pointer is stationary would cost us the idle budget.
        #expect(!DropCatcherView(frame: .zero).wantsPeriodicDraggingUpdates)
    }
}

/// Records what the view forwards, and answers with a fixed zone.
@MainActor private final class RecordingCatcherDelegate: DropCatcherDelegate {
    private let zone: Zone?
    var acceptsDrop = true
    private(set) var targetedPoints: [CGPoint] = []
    private(set) var droppedPoints: [CGPoint] = []
    private(set) var exitCount = 0

    init(zone: Zone?) { self.zone = zone }

    func catcher(_ view: DropCatcherView, targetedAt point: CGPoint) -> Zone? {
        targetedPoints.append(point)
        return zone
    }

    func catcherExited(_ view: DropCatcherView) { exitCount += 1 }

    func catcher(_ view: DropCatcherView, dropped info: any NSDraggingInfo, at point: CGPoint) -> Bool {
        droppedPoints.append(point)
        return acceptsDrop
    }
}
