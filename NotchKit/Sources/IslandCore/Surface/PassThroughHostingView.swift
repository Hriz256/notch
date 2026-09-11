import AppKit
import SwiftUI

/// Hosting view that only accepts clicks inside the island's current rect, so the
/// transparent rest of the window lets clicks through to whatever is underneath.
public final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    /// Returns the island rect in **screen** coordinates (origin bottom-left) — the same
    /// space `NSEvent.mouseLocation` and `HoverMonitor` use, so hover and hit-testing can
    /// share one provider and cannot drift apart.
    ///
    /// `hitTest` converts that rect into this view's own space, which is flipped
    /// (`NSHostingView.isFlipped == true`, origin top-left); comparing a screen or window
    /// rect against a flipped local point is what previously made the island unclickable.
    public var hitRectProvider: () -> CGRect = { .zero }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        // `convert(_:from: nil)` goes from the window's base space into this view's own,
        // honouring `isFlipped`; `point` arrives in the superview's space, which for a
        // content view is that same window base space.
        let islandRect = convert(window.convertFromScreen(hitRectProvider()), from: nil)
        guard islandRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}
