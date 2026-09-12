import AppKit
import CodeAgentShared
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import CodeAgentFeature
@testable import IslandCore

/// Renders the real ``SurfaceView`` offscreen and measures where the compact slots
/// actually put their glyphs.
///
/// The peek layout is arithmetic that every unit test agrees with and the screen did not:
/// the agent sprite drifted under the physical notch. Only a render can catch that, because
/// the drift comes from how a child view *measures*, not from any number the layout code
/// computes. So the island is rendered at its real metrics and the sprite is located by its
/// own color.
@MainActor
@Suite("Compact peek layout, rendered")
struct CompactLayoutRenderTests {
    // MARK: Fixtures

    /// A 14" MacBook Pro: 1728 × 1117 points, a 185 × 32 notch starting at x 771.
    static let metrics = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: 956, y: 1085, width: 772, height: 32)
    )

    /// Matches `SurfaceController.windowSize`: the island is centred in it, so the notch's
    /// mid-x lands on the window's mid-x.
    static let windowSize = CGSize(width: 640, height: 320)

    static func geometry() throws -> NotchGeometry {
        try #require(NotchGeometry(metrics: metrics))
    }

    /// Where the leading slot's centre must be, in the rendered view's coordinates.
    static func leadingSlotCentre(_ geometry: NotchGeometry) -> CGFloat {
        windowSize.width / 2 - geometry.notchWidth / 2 - IslandLayout.peekSlotWidth / 2
    }

    /// The left edge of the physical notch, in the rendered view's coordinates. Nothing the
    /// leading slot draws may cross it.
    static func notchLeftEdge(_ geometry: NotchGeometry) -> CGFloat {
        windowSize.width / 2 - geometry.notchWidth / 2
    }

    // MARK: Render harness

    /// A horizontal extent measured in points of the rendered view.
    struct Extent {
        var minX: CGFloat
        var maxX: CGFloat
        var midX: CGFloat { (minX + maxX) / 2 }
    }

    /// Renders a peek presentation with `leading` in the leading slot and returns the
    /// bounding extent of every pixel matching `color`.
    ///
    /// Returns `nil` when `ImageRenderer` cannot produce a bitmap (a headless CI box with no
    /// window server), so the test skips rather than fails.
    static func renderPeek(
        leading: AnyView,
        trailing: AnyView = AnyView(Color.clear),
        matching color: (red: CGFloat, green: CGFloat, blue: CGFloat),
        tolerance: CGFloat = 0.08
    ) throws -> Extent? {
        let geometry = try geometry()
        let presenter = IslandPresenter(clock: TaskClock())
        presenter.present(
            Presentation(
                featureID: FeatureID("code"),
                priority: .background,
                style: .peek,
                leading: leading,
                trailing: trailing,
                expanded: nil,
                expandedSize: CodeAgentViewModel.expandedSize
            )
        )

        let renderer = ImageRenderer(
            content: SurfaceView(presenter: presenter, geometry: geometry, choreographer: .standard)
                .frame(width: windowSize.width, height: windowSize.height)
        )
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return extent(of: image, matching: color, tolerance: tolerance, scale: 2)
    }

    /// Scans a rendered bitmap for pixels close to `color` and returns their horizontal
    /// extent in points.
    static func extent(
        of image: CGImage,
        matching color: (red: CGFloat, green: CGFloat, blue: CGFloat),
        tolerance: CGFloat,
        scale: CGFloat
    ) -> Extent? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = Int.max
        var maxX = Int.min
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = CGFloat(pixels[offset + 3]) / 255
                guard alpha > 0.5 else { continue }
                // Un-premultiply before comparing: the sprite is drawn opaque, but
                // antialiased edges arrive scaled by their coverage.
                let red = CGFloat(pixels[offset]) / 255 / alpha
                let green = CGFloat(pixels[offset + 1]) / 255 / alpha
                let blue = CGFloat(pixels[offset + 2]) / 255 / alpha
                guard abs(red - color.red) <= tolerance,
                      abs(green - color.green) <= tolerance,
                      abs(blue - color.blue) <= tolerance else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard minX <= maxX else { return nil }
        return Extent(minX: CGFloat(minX) / scale, maxX: CGFloat(maxX + 1) / scale)
    }

    // MARK: Tests

    @Test("The Claude sprite is centred in the leading peek slot")
    func agentIconIsCentredInItsSlot() throws {
        let geometry = try Self.geometry()
        guard let extent = try Self.renderPeek(
            leading: AnyView(AgentIcon(agent: .claude, size: 18).codeSlot()),
            matching: (0.96, 0.63, 0.54)
        ) else { return }  // No renderer on this machine; nothing to assert.

        let expected = Self.leadingSlotCentre(geometry)
        #expect(abs(extent.midX - expected) <= 2,
                "sprite centre \(extent.midX) pt, expected \(expected) pt (slot centre)")
        #expect(extent.maxX <= Self.notchLeftEdge(geometry),
                "sprite runs to \(extent.maxX) pt, under the notch at \(Self.notchLeftEdge(geometry)) pt")
    }

    @Test("A flexible leading slot — the shape Music uses — is centred too")
    func flexibleLeadingIsCentred() throws {
        let geometry = try Self.geometry()
        // Music's compact leading: a fixed-size glyph asked to fill whatever it is given.
        let control = AnyView(
            Rectangle()
                .fill(CodePalette.salmon)
                .frame(width: 18, height: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        guard let extent = try Self.renderPeek(leading: control, matching: (0.96, 0.63, 0.54)) else { return }

        let expected = Self.leadingSlotCentre(geometry)
        #expect(abs(extent.midX - expected) <= 2,
                "control centre \(extent.midX) pt, expected \(expected) pt")
    }

    /// The regression this file exists for.
    ///
    /// The peek row used to measure a fixed `notch + 2 * slot` and sit centred on the notch,
    /// so while `IslandFrame` interpolated the island's width — every hover in and out of
    /// the expanded card — the island's edges slid past a stationary glyph. Measured before
    /// the fix, the sprite's distance from the island's left edge walked 28 → 34.5 → 44.5 →
    /// 54.5 → 69.5 pt as the island grew to the Code card's 380 pt, ending 19 pt from the
    /// notch and reading as sitting under it.
    @Test("The leading glyph stays 28 pt from the island's edge at every width it grows through")
    func leadingSlotTracksTheIslandEdge() throws {
        let geometry = try Self.geometry()
        let notch = CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        let peekWidth = notch.width + 2 * IslandLayout.peekSlotWidth

        for width in [peekWidth, 310, 330, 350, CodeAgentViewModel.expandedSize.width] {
            let row = PeekRow(
                leading: AnyView(AgentIcon(agent: .claude, size: 18).codeSlot()),
                trailing: AnyView(Color.clear),
                notch: notch
            )
            .frame(width: width, height: notch.height, alignment: .top)

            let renderer = ImageRenderer(
                content: ZStack(alignment: .top) { row }
                    .frame(width: Self.windowSize.width, height: 64)
            )
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let extent = Self.extent(of: image, matching: (0.96, 0.63, 0.54), tolerance: 0.08, scale: 2)
            else { return }

            let islandLeft = Self.windowSize.width / 2 - width / 2
            #expect(abs(extent.midX - islandLeft - IslandLayout.peekSlotWidth / 2) <= 1,
                    "at island width \(width) the sprite sits \(extent.midX - islandLeft) pt from the left edge")
        }
    }

    @Test("The peek island is the same size whether the agent is idle or working")
    func peekSizeIgnoresTheExpandedSize() throws {
        let geometry = try Self.geometry()
        let presenter = IslandPresenter(clock: TaskClock())
        func layout(expandedSize: CGSize) -> IslandLayout {
            let presentation = Presentation(
                featureID: FeatureID("code"),
                priority: .background,
                style: .peek,
                leading: AnyView(Color.clear),
                trailing: AnyView(Color.clear),
                expanded: nil,
                expandedSize: expandedSize
            )
            presenter.present(presentation)
            defer { presenter.dismiss(presentation.id) }
            return IslandLayout.resolve(state: presenter.state, current: presenter.current, geometry: geometry)
        }

        let idle = layout(expandedSize: CodeAgentViewModel.expandedSize)
        let working = layout(expandedSize: CodeAgentViewModel.activitySize)
        #expect(idle.size == working.size)
        #expect(idle.size.width == geometry.notchWidth + 2 * IslandLayout.peekSlotWidth)
    }
}
