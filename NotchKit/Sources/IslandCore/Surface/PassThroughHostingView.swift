import AppKit
import SwiftUI

/// Hosting view that only accepts clicks inside the island's current rect, so the
/// transparent rest of the window lets clicks through to whatever is underneath.
public final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    /// Returns the island rect in this view's coordinate space (origin bottom-left).
    public var hitRectProvider: () -> CGRect = { .zero }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard hitRectProvider().contains(local) else { return nil }
        return super.hitTest(point)
    }
}
