import SwiftUI

/// Daily token totals as a smooth filled line — the "how has this week gone" glance
/// under the usage bars.
///
/// The caller draws the "Last 7 days" caption; this view is only the graph, so it can
/// also be dropped into a tighter layout without a heading.
struct SparklineView: View {
    /// Oldest first. Normalized against the largest value, so the shape shows the
    /// week's *relative* rhythm rather than absolute tokens (which mean little to a
    /// reader and differ wildly between agents).
    let values: [Double]
    var height: CGFloat = 34
    var tint: Color = CodePalette.salmon

    private static let lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            guard let points = Self.points(for: values, in: size) else { return }
            let line = Self.smoothPath(through: points)

            var fill = line
            fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            fill.addLine(to: CGPoint(x: points[0].x, y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.25), tint.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(
                line,
                with: .color(tint),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Evenly spaced sample points, normalized to the largest value. `nil` when there
    /// is nothing to draw. A week of zeros (or a single sample) lands flat on the
    /// baseline rather than dividing by zero or spiking to the top.
    static func points(for values: [Double], in size: CGSize) -> [CGPoint]? {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return nil }
        // Keep the stroke inside the frame: its centre never reaches the very edge.
        let inset = lineWidth / 2
        let top = inset
        let bottom = size.height - inset
        let maximum = values.max() ?? 0
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let normalized = maximum > 0 ? min(1, max(0, value / maximum)) : 0
            return CGPoint(x: CGFloat(index) * step, y: bottom - (bottom - top) * normalized)
        }
    }

    /// Catmull-Rom through every point, expressed as the equivalent cubic Béziers, so
    /// the curve passes through the samples instead of being pulled off them the way
    /// a plain Bézier through control points would be.
    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for index in 0..<(points.count - 1) {
            let p1 = points[index]
            let p2 = points[index + 1]
            // The segment's neighbours; the endpoints reuse themselves so the curve
            // starts and ends without an artificial overshoot.
            let p0 = points[max(index - 1, 0)]
            let p3 = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}
