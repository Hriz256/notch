import AppKit
import SwiftUI
import os

/// Owns the window, keeps it glued to the notch, and feeds hover state to the presenter.
@MainActor
public final class SurfaceController {
    private static let windowSize = CGSize(width: 640, height: 320)
    private let logger = Logger(subsystem: "app.notch", category: "surface")

    private let presenter: IslandPresenter
    private var window: SurfaceWindow?
    private var hostingView: PassThroughHostingView<SurfaceView>?
    /// The twin of ``window`` that stays in the ordinary user Space, so the system's drag
    /// image can composite above the island while a file is being dragged (see
    /// ``MirrorSwap``). Built with the window and kept empty and transparent until a drag
    /// starts.
    private var mirrorWindow: SurfaceWindow?
    private var mirrorHostingView: PassThroughHostingView<SurfaceView>?
    private var hoverMonitor: HoverMonitor?
    private var swipeMonitor: ScrollSwipeMonitor?
    private var geometry: NotchGeometry?
    private var screenObserver: (any NSObjectProtocol)?
    private var privateSpace: PrivateSpace?

    public private(set) var isVisible = false

    public init(presenter: IslandPresenter) {
        self.presenter = presenter
    }

    public func start() {
        // A private WindowServer Space at a top absolute level is what keeps the island
        // out of the Space-transition animation; without it the panel still works, it
        // just slides with the transition. No observer for
        // `activeSpaceDidChangeNotification`: it fires *after* the animation, so it can
        // never fix positioning, and once the panel lives in its own Space there is
        // nothing to re-assert.
        // Direct callback rather than observation: the presenter calls it in the same
        // main-actor turn the flag changes, which the grow animation depends on (see
        // ``IslandPresenter/setSurfaceMirrored(_:)``).
        presenter.onSurfaceMirroredChange = { [weak self] mirrored in
            self?.applyMirror(mirrored)
        }
        privateSpace = PrivateSpace()
        if privateSpace == nil {
            logger.warning("SkyLight private space unavailable; island will ride Space transitions")
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildIfNeeded() }
        }
        rebuildIfNeeded()
    }

    public func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        presenter.onSurfaceMirroredChange = nil
        privateSpace?.destroy()
        privateSpace = nil
        hoverMonitor?.stop()
        hoverMonitor = nil
        swipeMonitor?.stop()
        swipeMonitor = nil
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        // Closed, not merely ordered out: the mirror is rebuilt whenever the screen
        // changes, and a window that is only ordered out keeps its server-side backing
        // store for the rest of the session. `SurfaceWindow` is
        // `isReleasedWhenClosed = false`, so closing it with the last reference in hand
        // is safe (the drop catcher is torn down the same way).
        closeMirror()
        isVisible = false
    }

    /// Takes the mirror window down for good. The one place that closes it.
    private func closeMirror() {
        mirrorWindow?.orderOut(nil)
        mirrorWindow?.close()
        mirrorWindow = nil
        mirrorHostingView = nil
    }

    // MARK: Layout helpers

    /// Island rect in screen coordinates for the current state — the area the hover,
    /// swipe and click monitors treat as "over the island".
    ///
    /// While the island is expanded the rect is grown to the largest expanded card in the
    /// stack, not the card on screen. The cards differ in height (Music 160, Code 170, the
    /// stash 124), so a swipe that lands on a shorter card left the pointer *below* the new
    /// card, every following gesture was "outside" and the island read as frozen until the
    /// pointer moved. Growing the rect costs nothing visible: the black shape stays the
    /// card's own size, the extra band is transparent, and it only exists while hovering.
    private func islandScreenRect() -> CGRect {
        guard let geometry else { return .zero }
        let layout = IslandLayout.resolve(state: presenter.state, current: presenter.current, geometry: geometry)
        var size = layout.size
        if layout.mode == .expanded {
            for card in presenter.stack where card.expanded != nil {
                size.width = max(size.width, card.expandedSize.width)
                size.height = max(size.height, card.expandedSize.height)
            }
        }
        let midX = geometry.notchRect.midX
        return CGRect(
            x: midX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func rebuildIfNeeded() {
        guard let metrics = ScreenMetrics.current(), let newGeometry = NotchGeometry(metrics: metrics) else {
            logger.notice("No notch screen available; hiding surface")
            window?.orderOut(nil)
            mirrorWindow?.orderOut(nil)
            isVisible = false
            geometry = nil
            return
        }
        if newGeometry == geometry, window != nil { return }
        geometry = newGeometry
        buildWindow(for: newGeometry)
    }

    private func buildWindow(for geometry: NotchGeometry) {
        hoverMonitor?.stop()
        swipeMonitor?.stop()
        window?.orderOut(nil)
        // The old mirror is replaced a few lines down, so it is closed rather than left
        // ordered out: every screen change would otherwise leak one for the session.
        closeMirror()

        let frame = CGRect(
            x: geometry.notchRect.midX - Self.windowSize.width / 2,
            y: geometry.screenFrame.maxY - Self.windowSize.height,
            width: Self.windowSize.width,
            height: Self.windowSize.height
        )
        let panel = SurfaceWindow(contentRect: frame)
        let root = SurfaceView(presenter: presenter, geometry: geometry, choreographer: .current())
        let hosting = PassThroughHostingView(rootView: root)
        hosting.hitRectProvider = { [weak self] in self?.islandScreenRect() ?? .zero }
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        // Only now is `windowNumber` valid, so adoption has to follow the order-front.
        // Re-adopting on every rebuild is required and safe (the call is idempotent).
        privateSpace?.adopt(panel)

        // The mirror is built and ordered in *now*, empty and transparent, rather than
        // when a drag starts: a window created mid-drag does show the drag image on top
        // (the spike proved that much), but creating one is the most expensive thing that
        // could happen in the turn the island has to start growing, and the WindowServer
        // round trip is exactly what the swap cannot afford. It is deliberately *not*
        // adopted into the private Space — being in the ordinary user Space is the whole
        // point of it.
        let mirror = SurfaceWindow(contentRect: frame)
        mirror.ignoresMouseEvents = true
        mirror.alphaValue = 0
        mirror.setFrame(frame, display: false)
        mirror.orderFrontRegardless()

        let monitor = HoverMonitor(
            rectProvider: { [weak self] in self?.islandScreenRect() ?? .zero },
            onChange: { [weak self] inside in self?.presenter.setHovering(inside) }
        )
        monitor.start()

        let swipe = ScrollSwipeMonitor(
            rectProvider: { [weak self] in self?.islandScreenRect() ?? .zero },
            onSwipe: { [weak self] direction in self?.presenter.cycle(direction) }
        )
        swipe.start()

        window = panel
        hostingView = hosting
        mirrorWindow = mirror
        hoverMonitor = monitor
        swipeMonitor = swipe
        isVisible = true
        // A screen change mid-drag rebuilds both windows; the fresh pair has to come back
        // in whichever state the presenter is still in.
        applyMirror(presenter.isSurfaceMirrored)
        logger.info("Surface window built for notch \(geometry.notchRect.debugDescription, privacy: .public)")
    }

    // MARK: The mirror

    /// Moves the island's pixels between the primary window and the mirror.
    ///
    /// Activation installs a fresh hosting view over the same presenter — so the mirror
    /// draws exactly what the primary draws — and lays it out synchronously, before the
    /// alphas are swapped. That forced layout is what keeps the entrance animation: the
    /// mirror's SwiftUI view has to have rendered the island's *current* (collapsed or
    /// peek) shape before the zones presentation arrives, or SwiftUI coalesces the first
    /// render with the expansion and the panel appears fully grown instead of growing out
    /// of the notch.
    ///
    /// The mirror gets no `hitRectProvider`: it ignores mouse events entirely, and clicks
    /// keep going to the primary window, which is still there at alpha 0 (a transparent
    /// window still hit-tests — the drop catcher relies on the same thing).
    private func applyMirror(_ mirrored: Bool) {
        guard let window, let mirror = mirrorWindow, let geometry else { return }
        let swap = MirrorSwap.resolve(mirrored: mirrored)

        if swap.mirrorHasContent, mirrorHostingView == nil {
            let root = SurfaceView(presenter: presenter, geometry: geometry, choreographer: .current())
            let hosting = PassThroughHostingView(rootView: root)
            mirror.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            mirrorHostingView = hosting
        }

        // Mirror up first, primary down second: the other order shows one frame of
        // nothing where the island is.
        mirror.alphaValue = swap.mirrorAlpha
        window.alphaValue = swap.primaryAlpha

        if !swap.mirrorHasContent {
            mirror.contentView = nil
            mirrorHostingView = nil
        }
        logger.info("Surface mirror \(mirrored ? "engaged" : "released", privacy: .public)")
    }
}
