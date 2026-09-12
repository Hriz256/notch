import SwiftUI

/// The AirDrop mark: a filled dot with three arcs radiating up and out of it.
///
/// Drawn rather than taken from SF Symbols because there is no public AirDrop symbol —
/// the one macOS uses in the share sheet is private — and `wifi` (the usual stand-in) is
/// the wrong shape: its arcs are a narrow fan, AirDrop's wrap most of the way round the
/// dot and leave a gap only at the bottom. The reference frames show that wrap clearly,
/// so it is worth the twenty lines.
///
/// The geometry is specified in a 28 pt box and scaled to whatever frame it is given, so
/// one definition serves the 26 pt zone card and any smaller use later.
struct AirDropGlyph: View {
    /// The design size every number below is expressed in.
    static let designSize: CGFloat = 28

    /// Radii of the three waves, outward.
    static let waveRadii: [CGFloat] = [5.5, 9, 12.5]
    /// The filled centre.
    static let dotRadius: CGFloat = 2.2
    static let lineWidth: CGFloat = 1.5

    /// Each wave spans 125° → 415°, leaving a 70° gap centred on 90°, which in SwiftUI's
    /// y-down space is straight down: the arcs open upward and stop either side of the
    /// dot, exactly as the mark does.
    static let startAngle: Double = 125
    static let endAngle: Double = 415

    var color: Color = Palette.blue

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / Self.designSize
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            for radius in Self.waveRadii {
                var path = Path()
                path.addArc(
                    center: centre,
                    radius: radius * scale,
                    startAngle: .degrees(Self.startAngle),
                    endAngle: .degrees(Self.endAngle),
                    clockwise: false
                )
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: Self.lineWidth * scale, lineCap: .round)
                )
            }

            let dot = Self.dotRadius * scale
            context.fill(
                Path(ellipseIn: CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)),
                with: .color(color)
            )
        }
        .accessibilityLabel("AirDrop")
    }
}
