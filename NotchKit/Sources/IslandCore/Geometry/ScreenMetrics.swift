import AppKit

/// Snapshot of the numbers we need from NSScreen, so geometry is testable without a screen.
public struct ScreenMetrics: Sendable, Equatable {
    public var frame: CGRect
    public var safeAreaTop: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(frame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }

    /// The built-in display if it has a notch, otherwise nil.
    @MainActor
    public static func current() -> ScreenMetrics? {
        let candidates = NSScreen.screens
        guard let screen = candidates.first(where: { $0.safeAreaInsets.top > 0 }) else { return nil }
        return ScreenMetrics(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }
}
