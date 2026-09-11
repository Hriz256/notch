import Testing
import AppKit
import SwiftUI
@testable import IslandCore

@MainActor
struct PassThroughHostingViewTests {
    private static let windowSize = CGSize(width: 640, height: 320)
    private static let islandSize = CGSize(width: 185, height: 32)

    /// Offscreen borderless panel whose content view is the pass-through hosting view,
    /// with the provider returning a collapsed-notch-sized island rect (screen space,
    /// origin bottom-left) pinned to the top-center of the window.
    private func makeFixture() -> (panel: NSPanel, view: PassThroughHostingView<Color>) {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        let view = PassThroughHostingView(rootView: Color.black)
        panel.contentView = view
        panel.layoutIfNeeded()

        let frame = panel.frame
        view.hitRectProvider = {
            CGRect(x: frame.midX - Self.islandSize.width / 2,
                   y: frame.maxY - Self.islandSize.height,
                   width: Self.islandSize.width,
                   height: Self.islandSize.height)
        }
        return (panel, view)
    }

    /// `hitTest` receives points in the superview's space, which for a content view is
    /// the window's (unflipped) base space. This maps a point measured from the window's
    /// top-left — the way the island is laid out — into that space.
    private func windowPoint(x: CGFloat, downFromTop y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: Self.windowSize.height - y)
    }

    @Test func hitTestsOnlyTheIslandBody() {
        let (panel, view) = makeFixture()
        defer { panel.contentView = nil }

        // Middle of the island, 16 pt below the top edge of the window.
        #expect(view.hitTest(windowPoint(x: 320, downFromTop: 16)) != nil)
        // 300 pt further down: empty, transparent window area.
        #expect(view.hitTest(windowPoint(x: 320, downFromTop: 316)) == nil)
        // The flare corners either side of the 185 pt body (x ∈ [227.5, 412.5]).
        #expect(view.hitTest(windowPoint(x: 222, downFromTop: 16)) == nil)
        #expect(view.hitTest(windowPoint(x: 418, downFromTop: 16)) == nil)
    }
}
