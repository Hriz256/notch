import AppKit
import DropZonesShared
import os

/// The window and its view are two halves of one thing and log as one: the ordering
/// belongs to the window, the drag messages to the view, and reading them apart is exactly
/// what makes a missing drop hard to explain.
private let logger = Logger(subsystem: "app.notch", category: "dropzones.catcher")

/// What the catcher tells the feature about the drag passing over it.
///
/// Everything is in panel coordinates (origin top-left, the space
/// ``ZoneLayout`` lays the cards out in), so the delegate answers with a plain
/// `hitTest` and never has to know where on screen the island happens to be.
@MainActor
public protocol DropCatcherDelegate: AnyObject {
    /// Which zone is under `point`, or `nil` between the cards. The return value
    /// decides whether the drag is accepted, so answering `nil` is how a drop in
    /// a gap gets refused.
    func catcher(_ view: DropCatcherView, targetedAt point: CGPoint) -> Zone?
    /// The cursor left the catcher's frame without dropping.
    func catcherExited(_ view: DropCatcherView)
    /// The user let go at `point`; `false` tells the source the drop failed.
    func catcher(_ view: DropCatcherView, dropped info: any NSDraggingInfo, at point: CGPoint) -> Bool
}

/// The invisible window that actually receives the drop.
///
/// The island itself cannot: the spike proved that a window in a private
/// SkyLight space is invisible to drag hit-testing — it neither receives drops
/// nor blocks the normal-space window beneath it (`research/drop-zones-macos.md`,
/// "Spike results"). So the island keeps drawing the zones and this window,
/// sitting in the ordinary space exactly over them at `alphaValue 0`, takes the
/// drag messages. AppKit routes them to a fully transparent window quite happily.
///
/// It is ordered in **once**, at activation, and from then on only moved and
/// toggled between opaque and transparent to the mouse. That is not tidiness: a
/// drag's destination is re-resolved by AppKit as the pointer moves, and a window
/// that joins the window list while a drag is already in flight can be skipped
/// altogether — which is what a session with no `draggingEntered` at all, and a
/// drop that fell through to the desktop, looks like. Between drags the window
/// is invisible (`alphaValue 0`) and `ignoresMouseEvents`, so a window parked
/// over the notch never swallows a click.
public final class DropCatcherWindow: NSPanel {

    /// The destination view. Exposed so the feature can set its `panelFrame` and
    /// delegate; it is always this window's `contentView`.
    public let catcherView: DropCatcherView

    public init() {
        catcherView = DropCatcherView(frame: .zero)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        alphaValue = 0
        // One above the island (`SurfaceWindow` = statusWindow + 1). Being above
        // it costs nothing visually at alpha 0 and keeps the drag hit test from
        // ever landing on another status-level window first.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        ignoresMouseEvents = true
        contentView = catcherView
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// The frame is exactly what the owner asks for. AppKit's default nudges a window
    /// whose frame reaches the screen's top edge down onto the visible area, which would
    /// slide the catcher off the panel it has to sit exactly over and make every hit test
    /// land in the wrong place.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Puts the window into the window list, at `frame`, invisible and transparent
    /// to the mouse. Called once per activation, before any drag can start.
    ///
    /// `orderFrontRegardless` rather than `orderFront`: the app is an accessory and
    /// is never the active one, and an ordinary `orderFront` from a background app
    /// can be ignored.
    public func activate(frame: CGRect) {
        ignoresMouseEvents = true
        setFrame(frame, display: false)
        orderFrontRegardless()
        logger.info("""
            catcher ordered in window=\(self.windowNumber, privacy: .public) \
            visible=\(self.isVisible, privacy: .public) \
            frame=\(NSStringFromRect(frame), privacy: .public)
            """)
    }

    /// Puts the catcher over `frame` (screen coordinates) and starts accepting
    /// drags. Calling it again while shown just moves it, which is what happens
    /// as the panel widens under the cursor.
    public func show(frame: CGRect) {
        setFrame(frame, display: false)
        catcherView.resetEntryCount()
        // A `panelFrame` nobody set is the one failure mode of this window that is
        // completely silent: every hit test lands at a screen-absolute coordinate,
        // no zone is ever under the cursor, and the drop is refused with no sign of
        // why. The catcher's frame always contains the panel, so it is the sane
        // default — the owner still overwrites it with the real panel rect, and an
        // explicit value is never clobbered.
        if catcherView.panelFrame == .zero {
            catcherView.panelFrame = frame
        }
        ignoresMouseEvents = false
        // A window that is somehow not in the list any more (the app was hidden,
        // the screen configuration changed under us) is put back — and said so,
        // because ordering in mid-drag is exactly the case that can cost a drop.
        if !isVisible {
            logger.error("catcher was not in the window list when the zones opened; ordering it in mid-drag")
            orderFrontRegardless()
        }
        // Info rather than debug: this is the state that decides whether a drop
        // can reach us at all, and debug lines are dropped unless streamed.
        logger.info("""
            catcher shown at \(NSStringFromRect(frame), privacy: .public) \
            window=\(self.windowNumber, privacy: .public) \
            visible=\(self.isVisible, privacy: .public) \
            occlusion=\(self.occlusionState.rawValue, privacy: .public) \
            screen=\(self.screen.map { NSStringFromRect($0.frame) } ?? "none", privacy: .public)
            """)
    }

    /// Stops the catcher taking drags. The window stays in the list, invisible and
    /// transparent to the mouse — see the type's note on ordering.
    public func hide() {
        ignoresMouseEvents = true
        logger.debug("catcher hidden (still ordered in)")
    }

    /// Takes the window out of the list for good. The one place that orders it out,
    /// called when the feature is switched off.
    public func deactivate() {
        ignoresMouseEvents = true
        orderOut(nil)
        close()
        logger.info("catcher ordered out and closed")
    }

    /// One line describing where the catcher stands, for the log when a drop that
    /// should have arrived never did.
    var diagnostics: String {
        """
        catcher window=\(windowNumber) visible=\(isVisible) \
        ignoresMouse=\(ignoresMouseEvents) occlusion=\(occlusionState.rawValue) \
        frame=\(NSStringFromRect(frame)) entered=\(catcherView.entryCount)
        """
    }
}

/// The catcher's content view: an `NSDraggingDestination` that converts the
/// cursor into panel coordinates and forwards everything to its delegate.
///
/// `NSView` already conforms to `NSDraggingDestination`, so the callbacks are
/// overrides rather than a fresh conformance.
public final class DropCatcherView: NSView {

    /// Weak, like every AppKit delegate: the feature owns the window, and the
    /// window owns this view.
    public weak var delegate: (any DropCatcherDelegate)?

    /// Where the island's zones panel is on screen (origin bottom-left). Set by
    /// the owner whenever the panel moves or resizes; it is what makes the
    /// catcher's idea of "over the stash card" the same as the one the user sees,
    /// even when the catcher's own frame is larger than the panel.
    public var panelFrame: CGRect = .zero

    /// How many drags have entered since the zones last went up. Zero at the end of a
    /// showing means AppKit never offered this window the drag at all — the one failure
    /// that is indistinguishable, from the view model's side, from a user who let go
    /// just outside a card.
    private(set) var entryCount = 0

    /// `panelFrame` is defaulted by `DropCatcherWindow.show(frame:)`, so a zero one
    /// here means the view is receiving drags without ever having been shown —
    /// worth exactly one line in the log, not one per mouse move.
    private var didWarnAboutMissingPanelFrame = false

    /// `.fileURL` and the promise types are the payloads we read; `.URL` is
    /// registered too because some sources hand a file over under it. `.png` and
    /// `.tiff` cover a dragged image that is not a file anywhere.
    public static let draggedTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:))
        + [.fileURL, .URL, .png, .tiff]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.draggedTypes)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("DropCatcherView is not loaded from a nib") }

    /// A timer while the pointer sits still would cost the idle budget for
    /// nothing: the zone under the cursor cannot change without a mouse move.
    /// `@objc` because `NSView` declares the conformance but not this member, so
    /// AppKit finds it by selector rather than through a witness table.
    @objc public var wantsPeriodicDraggingUpdates: Bool { false }

    // MARK: - Coordinates

    /// Screen point (origin bottom-left) → panel point (origin top-left).
    ///
    /// Deliberately unclamped: a cursor outside the panel produces coordinates
    /// outside it, the hit test answers "no zone", and the drag is refused —
    /// which is the honest outcome when the catcher is larger than the panel.
    public func panelPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - panelFrame.minX, y: panelFrame.maxY - point.y)
    }

    /// Where this drag is, in panel coordinates. `draggingLocation` is in the
    /// destination *window's* coordinates, so it goes through the window first.
    private func panelPoint(of info: any NSDraggingInfo) -> CGPoint {
        warnIfPanelFrameIsMissing()
        let screen = window?.convertPoint(toScreen: info.draggingLocation) ?? info.draggingLocation
        return panelPoint(fromScreen: screen)
    }

    /// Logs the silent failure once per view, from whichever dragging callback
    /// notices it first.
    private func warnIfPanelFrameIsMissing() {
        guard panelFrame == .zero, !didWarnAboutMissingPanelFrame else { return }
        didWarnAboutMissingPanelFrame = true
        logger.error("catcher received a drag with no panelFrame — every hit test will miss")
    }

    // MARK: - NSDraggingDestination

    /// Forgets the entries of the previous showing. Called by the window as the zones
    /// go up, so ``entryCount`` always describes the drag in flight.
    func resetEntryCount() {
        entryCount = 0
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        entryCount += 1
        let op = operation(for: sender)
        logger.info("""
            draggingEntered → \(op.rawValue, privacy: .public) \
            at \(NSStringFromPoint(self.panelPoint(of: sender)), privacy: .public) \
            panelFrame=\(NSStringFromRect(self.panelFrame), privacy: .public)
            """)
        return op
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        // The other half of the entry trail: an exit with no drop after it is a drag that
        // left the notch, and an exit that arrives *instead* of `performDragOperation` is
        // a drop AppKit decided was not ours.
        logger.info("draggingExited after \(self.entryCount, privacy: .public) entry/entries")
        delegate?.catcherExited(self)
    }

    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let accepted = delegate?.catcher(self, dropped: sender, at: panelPoint(of: sender)) ?? false
        logger.debug("performDragOperation → \(accepted, privacy: .public)")
        return accepted
    }

    /// `.copy` over a card, nothing anywhere else.
    ///
    /// Never `.move`, which would ask the source application to delete the user's
    /// original, and never `.link`, which shows an alias badge we do not honour.
    private func operation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard let delegate, delegate.catcher(self, targetedAt: panelPoint(of: sender)) != nil else {
            return []
        }
        return .copy
    }
}
