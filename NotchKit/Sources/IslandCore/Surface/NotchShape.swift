import SwiftUI

/// Black island silhouette. The top corners flare outward (concave) so the shape
/// merges with the menu-bar notch; the bottom corners are convex.
/// `rect` includes the flares: body width = rect.width - 2 * topRadius.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    public func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.height / 2)
        // Radii animate independently of the frame, so mid-transition a large bottom radius can
        // meet a small height. Cap at half the height as well so the corners never swallow the
        // straight edge between them (steady-state radii are all well under this cap).
        let b = min(bottomRadius, max(0, rect.height - t), rect.height / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
