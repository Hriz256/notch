import CoreGraphics

/// Pure mapping from island state to the black shape's size and corner radii.
public struct IslandLayout: Equatable, Sendable {
    public enum Mode: Sendable { case collapsed, peek, expanded }

    public static let peekSlotWidth: CGFloat = 56

    public var mode: Mode
    public var size: CGSize
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    /// True when `next` grows on neither axis: the island is collapsing back toward the notch.
    /// Equal layouts count as shrinking; the curve is then irrelevant, nothing moves.
    public func shrinks(to next: IslandLayout) -> Bool {
        next.size.width <= size.width && next.size.height <= size.height
    }

    @MainActor
    public static func resolve(state: IslandState, current: Presentation?, geometry: NotchGeometry) -> IslandLayout {
        let notch = CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        let peekWidth = notch.width + 2 * peekSlotWidth
        switch state {
        case .collapsed:
            return IslandLayout(mode: .collapsed, size: notch, topRadius: 6, bottomRadius: 10)
        case .peek:
            guard current != nil else { return resolve(state: .collapsed, current: nil, geometry: geometry) }
            return IslandLayout(mode: .peek, size: CGSize(width: peekWidth, height: notch.height), topRadius: 8, bottomRadius: 14)
        case .expanded:
            guard let current else { return resolve(state: .collapsed, current: nil, geometry: geometry) }
            let width = max(current.expandedSize.width, peekWidth)
            let height = max(current.expandedSize.height, notch.height)
            return IslandLayout(mode: .expanded, size: CGSize(width: width, height: height), topRadius: 12, bottomRadius: 24)
        }
    }
}
