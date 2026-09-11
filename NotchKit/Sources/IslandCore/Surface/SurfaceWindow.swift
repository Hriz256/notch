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
