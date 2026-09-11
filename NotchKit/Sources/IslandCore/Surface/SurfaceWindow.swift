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
        // `.screenSaver` (1000) rather than `statusWindow + 1` (26): at status level the
        // panel is treated as ordinary window content by the WindowServer, so it is
        // captured by the Space-transition snapshot and gets scaled/slid with it —
        // visible as the island shrinking and drifting when a full-screen app exits or
        // Mission Control opens. Screen-saver level sits above that transition layer, so
        // the island stays put and unscaled. Menu bar is 24 and status items 25, so this
        // still renders over them, which is what a notch surface needs.
        level = .screenSaver
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
