import AppKit

/// Borderless, non-activating panel that floats above the menu bar on every Space.
public final class SurfaceWindow: NSPanel {
    public init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // 26 = one above the status-item level (menu bar is 24, status items 25), so the
        // island renders over them — the same level Seam uses. Raising it further does
        // *not* keep the panel still during Space transitions; that is ``PrivateSpace``'s
        // job (the window is moved into a private WindowServer Space at a top absolute
        // level, which is the only mechanism that takes it out of the transition).
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
