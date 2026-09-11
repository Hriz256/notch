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
    private var hoverMonitor: HoverMonitor?
    private var geometry: NotchGeometry?
    private var screenObserver: (any NSObjectProtocol)?

    public private(set) var isVisible = false

    public init(presenter: IslandPresenter) {
        self.presenter = presenter
    }

    public func start() {
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
        hoverMonitor?.stop()
        hoverMonitor = nil
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        isVisible = false
    }

    // MARK: Layout helpers

    /// Island rect in screen coordinates for the current state.
    private func islandScreenRect() -> CGRect {
        guard let geometry else { return .zero }
        let layout = IslandLayout.resolve(state: presenter.state, current: presenter.current, geometry: geometry)
        let midX = geometry.notchRect.midX
        return CGRect(
            x: midX - layout.size.width / 2,
            y: geometry.screenFrame.maxY - layout.size.height,
            width: layout.size.width,
            height: layout.size.height
        )
    }

    private func rebuildIfNeeded() {
        guard let metrics = ScreenMetrics.current(), let newGeometry = NotchGeometry(metrics: metrics) else {
            logger.notice("No notch screen available; hiding surface")
            window?.orderOut(nil)
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
        window?.orderOut(nil)

        let frame = CGRect(
            x: geometry.notchRect.midX - Self.windowSize.width / 2,
            y: geometry.screenFrame.maxY - Self.windowSize.height,
            width: Self.windowSize.width,
            height: Self.windowSize.height
        )
        let panel = SurfaceWindow(contentRect: frame)
        let root = SurfaceView(presenter: presenter, geometry: geometry, choreographer: .current())
        let hosting = PassThroughHostingView(rootView: root)
        hosting.hitRectProvider = { [weak self, weak panel] in
            guard let self, let panel else { return .zero }
            let screenRect = self.islandScreenRect()
            let windowRect = panel.convertFromScreen(screenRect)
            return windowRect
        }
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        let monitor = HoverMonitor(
            rectProvider: { [weak self] in self?.islandScreenRect() ?? .zero },
            onChange: { [weak self] inside in self?.presenter.setHovering(inside) }
        )
        monitor.start()

        window = panel
        hostingView = hosting
        hoverMonitor = monitor
        isVisible = true
        logger.info("Surface window built for notch \(geometry.notchRect.debugDescription, privacy: .public)")
    }
}
