import CoreGraphics

/// Where the notch is, in screen coordinates (origin bottom-left, like AppKit).
public struct NotchGeometry: Sendable, Equatable {
    public let screenFrame: CGRect
    public let notchRect: CGRect

    public var notchWidth: CGFloat { notchRect.width }
    public var notchHeight: CGFloat { notchRect.height }

    public init?(metrics: ScreenMetrics) {
        guard metrics.safeAreaTop > 0,
              let left = metrics.auxiliaryTopLeft,
              let right = metrics.auxiliaryTopRight,
              right.minX > left.maxX else { return nil }
        screenFrame = metrics.frame
        notchRect = CGRect(
            x: left.maxX,
            y: metrics.frame.maxY - metrics.safeAreaTop,
            width: right.minX - left.maxX,
            height: metrics.safeAreaTop
        )
    }
}
