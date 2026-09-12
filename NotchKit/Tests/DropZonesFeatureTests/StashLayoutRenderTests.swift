import AppKit
import CoreGraphics
import DropZonesShared
import Foundation
import SwiftUI
import Testing

@testable import DropZonesFeature
@testable import IslandCore

// MARK: - Doubles

@MainActor
private final class StubPresenter: IslandPresenting {
    func present(_ presentation: Presentation) {}
    func update(_ presentation: Presentation) {}
    func dismiss(_ id: PresentationID) {}
}

/// A clock the test drives by hand, so the 0.4 s settle is over the moment the drop is.
@MainActor
private final class ManualClock: IslandClock {
    private struct Entry {
        let due: Duration
        let action: @MainActor () -> Void
        let id: Int
    }

    private var entries: [Entry] = []
    private var nextID = 0
    private var now: Duration = .zero

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let id = nextID
        nextID += 1
        entries.append(Entry(due: now + delay, action: action, id: id))
        return ScheduledToken { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    func advance(by delta: Duration) {
        let target = now + delta
        while let next = entries.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            entries.removeAll { $0.id == next.id }
            next.action()
        }
        now = target
    }
}

/// A solid red bitmap: the thumbnails have to be findable by colour, and no other part of
/// the island is red.
private func redImage() -> CGImage {
    let context = CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return context.makeImage()!
}

/// A view model with real files in a temporary stash, and thumbnails already generated.
@MainActor
private final class RenderHarness {
    let root: URL
    let sources: URL
    let suite: String
    let clock = ManualClock()
    let model: DropZonesViewModel

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StashLayoutRenderTests-\(UUID().uuidString)")
        sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        suite = "app.notch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        model = DropZonesViewModel(
            presenter: StubPresenter(),
            clock: clock,
            settings: DropZonesSettings(defaults: defaults),
            store: StashStore(baseDirectory: root.appendingPathComponent("Notch", isDirectory: true)),
            thumbnails: ThumbnailProvider(size: 22, scale: 2, generator: { _ in redImage() }),
            airDrop: { _ in true },
            viewFactory: .placeholder
        )
    }

    /// Puts `names` in the stash the way a drop does, and waits for their thumbnails.
    func stash(_ names: [String]) async throws {
        var urls: [URL] = []
        for name in names {
            let url = sources.appendingPathComponent(name)
            try Data("hello".utf8).write(to: url)
            urls.append(url)
        }
        model.handle(.enteredHotRect)
        await model.drop(urls: urls, on: .stash)
        clock.advance(by: .milliseconds(500))

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline, model.thumbnails.count < names.count {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Bitmap scanning

/// Where a colour lands in a rendered view, in points.
private struct Region {
    var minX: CGFloat
    var maxX: CGFloat
    var minY: CGFloat
    var maxY: CGFloat
    /// Matching device pixels. A handful of antialiased strays satisfy any position
    /// assertion, so every test also states how much ink it expected to find.
    var count: Int
    /// The ink's centre of mass, which is what "centred in the slot" means.
    var centroid: CGPoint
}

private enum Ink {
    /// The injected thumbnails.
    static func isRed(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
        r > 0.6 && g < 0.35 && b < 0.35
    }

    /// The panel's own shape. Nothing else in a rendered panel is this dark.
    static func isBlack(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
        r < 0.15 && g < 0.15 && b < 0.15
    }

    /// `.systemBlue`, read back through whatever appearance the renderer used. Matched by
    /// shape rather than by exact components: the accent follows the user's settings, and
    /// a literal would make this test fail on a machine with a different one.
    static func isBlue(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
        b > 0.55 && b - r > 0.3 && b - g > 0.12
    }
}

/// Finds every pixel matching `matches` inside `rows` (in points) and measures it.
private func scan(
    _ image: CGImage,
    scale: CGFloat = 2,
    rows: ClosedRange<CGFloat>? = nil,
    matches: (CGFloat, CGFloat, CGFloat) -> Bool
) -> Region? {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixels,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: width * 4,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    var count = 0
    var sumX = 0.0, sumY = 0.0
    for y in 0..<height {
        if let rows {
            let point = CGFloat(y) / scale
            guard rows.contains(point) else { continue }
        }
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let alpha = CGFloat(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            // Un-premultiply: the ink is drawn opaque, but its antialiased edges arrive
            // scaled by their coverage.
            let r = CGFloat(pixels[offset]) / 255 / alpha
            let g = CGFloat(pixels[offset + 1]) / 255 / alpha
            let b = CGFloat(pixels[offset + 2]) / 255 / alpha
            guard matches(r, g, b) else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            count += 1
            sumX += Double(x); sumY += Double(y)
        }
    }
    guard count > 0 else { return nil }
    return Region(
        minX: CGFloat(minX) / scale,
        maxX: CGFloat(maxX + 1) / scale,
        minY: CGFloat(minY) / scale,
        maxY: CGFloat(maxY + 1) / scale,
        count: count,
        centroid: CGPoint(
            x: (sumX / Double(count) + 0.5) / scale,
            y: (sumY / Double(count) + 0.5) / scale
        )
    )
}

// MARK: - Tests

/// Renders the real stash views offscreen and measures where they actually put things.
///
/// The peek's arithmetic is agreed on by every unit test in the package; what it cannot
/// catch is a glyph that *measures* differently from how it draws and so drifts under the
/// physical notch. That is a bitmap question, so these tests ask it in bitmaps — the same
/// approach, and the same harness shape, as `CompactLayoutRenderTests`.
@MainActor
@Suite("Stash layout, rendered")
struct StashLayoutRenderTests {

    /// A 14" MacBook Pro: a 185 × 32 notch on a 1728 × 1117 screen.
    static let metrics = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: 956, y: 1085, width: 772, height: 32)
    )

    /// Matches `SurfaceController.windowSize`; the island is centred in it and hugs the top.
    static let windowSize = CGSize(width: 640, height: 320)

    static func geometry() throws -> NotchGeometry {
        try #require(NotchGeometry(metrics: metrics))
    }

    /// Where each peek slot's centre must be, in the rendered view's coordinates.
    static func leadingSlotCentre(_ geometry: NotchGeometry) -> CGFloat {
        windowSize.width / 2 - geometry.notchWidth / 2 - IslandLayout.peekSlotWidth / 2
    }

    static func trailingSlotCentre(_ geometry: NotchGeometry) -> CGFloat {
        windowSize.width / 2 + geometry.notchWidth / 2 + IslandLayout.peekSlotWidth / 2
    }

    /// The vertical middle of the peek row — the island's top edge is the window's top.
    static func slotCentreY(_ geometry: NotchGeometry) -> CGFloat {
        geometry.notchHeight / 2
    }

    // MARK: Harness

    /// Renders `view` as the island's peek content, through the real `SurfaceView`.
    ///
    /// `nil` — and only then — when `ImageRenderer` cannot produce a bitmap at all, which
    /// is the one case a test may skip.
    static func renderPeek(leading: AnyView, trailing: AnyView) throws -> CGImage? {
        let geometry = try geometry()
        let presenter = IslandPresenter(clock: TaskClock())
        presenter.present(
            Presentation(
                featureID: DropZonesViewModel.featureID,
                priority: .background,
                style: .peek,
                leading: leading,
                trailing: trailing,
                expanded: nil,
                expandedSize: DropZonesViewModel.stashExpandedSize
            )
        )
        return render(
            SurfaceView(presenter: presenter, geometry: geometry, choreographer: .standard)
        )
    }

    /// Renders `expanded` as the island's expanded content, through the real `SurfaceView`.
    static func renderExpanded(_ expanded: AnyView, size: CGSize) throws -> CGImage? {
        let geometry = try geometry()
        let presenter = IslandPresenter(clock: TaskClock())
        presenter.present(
            Presentation(
                featureID: DropZonesViewModel.featureID,
                // `.alert` is what the zones panel uses, and it is expanded the instant it
                // is presented — no hover to simulate, no clock to advance.
                priority: .alert,
                style: .expanded,
                leading: AnyView(EmptyView()),
                trailing: AnyView(EmptyView()),
                expanded: expanded,
                expandedSize: size
            )
        )
        return render(
            SurfaceView(presenter: presenter, geometry: geometry, choreographer: .standard)
        )
    }

    static func render(_ view: some View, size: CGSize = windowSize) -> CGImage? {
        let renderer = ImageRenderer(
            content: AnyView(
                view
                    .frame(width: size.width, height: size.height)
                    // `ImageRenderer` paints a placeholder over an `NSViewRepresentable`
                    // rather than what is under it; without this every measurement below
                    // would be of that placeholder.
                    .environment(\.stashDragEnabled, false)
            )
        )
        renderer.scale = 2
        return renderer.cgImage
    }

    // MARK: The peek

    @Test("The thumbnail stack is centred in the leading peek slot")
    func stackIsCentredInTheLeadingSlot() async throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        try await harness.stash(["Screenshot.png"])

        let geometry = try Self.geometry()
        let image = try #require(
            try Self.renderPeek(
                leading: AnyView(StashLeadingView(model: harness.model)),
                trailing: AnyView(Color.clear)
            ),
            "the renderer produced no bitmap"
        )

        let region = try #require(scan(image, matches: Ink.isRed),
                                  "no thumbnail in the rendered island at all")
        // A 22 pt tile at 2× is 1936 device pixels; far under that means it was clipped.
        #expect(region.count >= 1500, "only \(region.count) thumbnail pixels rendered")
        #expect(abs(region.maxX - region.minX - ThumbnailStackTokens.compact.thumbSize) <= 2,
                "the tile measured \(region.maxX - region.minX) pt across")
        #expect(abs(region.centroid.x - Self.leadingSlotCentre(geometry)) <= 2,
                "stack centre \(region.centroid.x) pt, expected \(Self.leadingSlotCentre(geometry)) pt")
        #expect(abs(region.centroid.y - Self.slotCentreY(geometry)) <= 2,
                "stack centre \(region.centroid.y) pt, expected \(Self.slotCentreY(geometry)) pt")
        // Nothing the leading slot draws may cross under the notch.
        #expect(region.maxX <= Self.windowSize.width / 2 - geometry.notchWidth / 2,
                "the stack runs to \(region.maxX) pt, under the notch")
    }

    @Test("The count circle is centred in the trailing peek slot")
    func countCircleIsCentredInTheTrailingSlot() async throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        try await harness.stash(["a.png", "b.png"])

        let geometry = try Self.geometry()
        let image = try #require(
            try Self.renderPeek(
                leading: AnyView(Color.clear),
                trailing: AnyView(StashTrailingView(model: harness.model))
            ),
            "the renderer produced no bitmap"
        )

        let region = try #require(scan(image, matches: Ink.isBlue),
                                  "no count badge in the rendered island at all")
        #expect(region.count >= 200, "only \(region.count) badge pixels rendered")
        #expect(abs(region.centroid.x - Self.trailingSlotCentre(geometry)) <= 2,
                "badge centre \(region.centroid.x) pt, expected \(Self.trailingSlotCentre(geometry)) pt")
        #expect(abs(region.centroid.y - Self.slotCentreY(geometry)) <= 2,
                "badge centre \(region.centroid.y) pt, expected \(Self.slotCentreY(geometry)) pt")
        // 18 pt across, with the stroke's antialiasing either side.
        #expect(region.maxX - region.minX <= FileCountCircle.diameter + 3)
    }

    // MARK: The hover-expanded card

    @Test("Hovering the stash card moves neither the stack nor the badge")
    func expandedCardKeepsThePeeksPositions() async throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        try await harness.stash(["Screenshot.png"])

        let geometry = try Self.geometry()
        let image = try #require(
            try Self.renderExpanded(
                AnyView(StashExpandedView(model: harness.model)),
                size: DropZonesViewModel.stashExpandedSize
            ),
            "the renderer produced no bitmap"
        )

        let stack = try #require(scan(image, matches: Ink.isRed),
                                 "no thumbnail in the rendered expanded card")
        #expect(abs(stack.centroid.x - Self.leadingSlotCentre(geometry)) <= 2,
                "stack centre \(stack.centroid.x) pt, expected \(Self.leadingSlotCentre(geometry)) pt")
        #expect(abs(stack.centroid.y - Self.slotCentreY(geometry)) <= 2,
                "stack centre \(stack.centroid.y) pt, expected \(Self.slotCentreY(geometry)) pt; the expanded card must not push the peek row down")

        // The badge, measured only in the top row so the caption's tray glyph cannot be
        // mistaken for it.
        let badge = try #require(
            scan(image, rows: 0...geometry.notchHeight, matches: Ink.isBlue),
            "no count badge in the expanded card's top row"
        )
        #expect(abs(badge.centroid.x - Self.trailingSlotCentre(geometry)) <= 2,
                "badge centre \(badge.centroid.x) pt, expected \(Self.trailingSlotCentre(geometry)) pt")
    }

    @Test("The caption row sits 26 pt below the notch")
    func captionSitsBelowTheNotch() async throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        try await harness.stash(["Screenshot.png"])

        let geometry = try Self.geometry()
        let image = try #require(
            try Self.renderExpanded(
                AnyView(StashExpandedView(model: harness.model)),
                size: DropZonesViewModel.stashExpandedSize
            ),
            "the renderer produced no bitmap"
        )

        // Everything blue below the notch is the caption's tray glyph.
        let caption = try #require(
            scan(image, rows: geometry.notchHeight...76, matches: Ink.isBlue),
            "no caption glyph under the notch"
        )
        let expected = geometry.notchHeight + 26
        #expect(abs(caption.centroid.y - expected) <= 3,
                "caption centre \(caption.centroid.y) pt, expected \(expected) pt")
    }

    // MARK: The zones panel

    /// The catcher window's content size: the panel grown by the slack on every side.
    static let catcherSize = CGSize(
        width: ZoneLayout.panelSize.width + 2 * DropZonesFeature.catcherSlack,
        height: ZoneLayout.panelSize.height + 2 * DropZonesFeature.catcherSlack
    )

    /// Where the panel's top-left corner lands inside that view — which puts its top edge
    /// on the screen's top edge and its centre on the notch's.
    static let panelOrigin = CGPoint(x: DropZonesFeature.catcherSlack, y: DropZonesFeature.catcherSlack)

    /// Renders the zones the way they are really shown: as `ZonesPanelView`, filling the
    /// drop catcher's window. That view owns the black shape, the slack the panel sits
    /// inside and the notch the shape grows out of, so measuring anything less would let
    /// the cards and the window they are hit-tested in drift apart unnoticed.
    static func renderZones(_ model: DropZonesViewModel) throws -> CGImage? {
        let geometry = try geometry()
        return render(
            ZonesPanelView(
                model: model,
                notchSize: CGSize(width: geometry.notchWidth, height: geometry.notchHeight),
                choreographer: .standard
            ),
            size: catcherSize
        )
    }

    @Test("The panel sits exactly where the island's expanded panel used to")
    func panelLandsAtTheSlackInsideTheCatcher() throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        harness.model.handle(.enteredHotRect)

        let image = try #require(try Self.renderZones(harness.model), "the renderer produced no bitmap")
        let panel = try #require(scan(image, matches: Ink.isBlack), "the panel drew no black shape")

        // The catcher's window is the panel's screen rect inset by −20, so 20 pt in from
        // its top and left edge is the panel's own top-left — screen top, notch centre.
        let expected = CGRect(origin: Self.panelOrigin, size: ZoneLayout.panelSize)
        #expect(abs(panel.minY - expected.minY) <= 1, "the panel starts at y \(panel.minY) pt")
        #expect(abs(panel.maxY - expected.maxY) <= 1, "the panel ends at y \(panel.maxY) pt")
        // Sideways the outermost points of a `NotchShape` are the tips of its two top
        // flares, which taper to nothing: the last few columns are thin enough that no
        // pixel in them is more than half covered, so the measured edges sit a little
        // inside the frame. What has to be exact is that they sit *symmetrically*
        // inside it — the panel is centred on the notch, and a drop is hit-tested
        // against that centre.
        let flare = ZonesPanelView.topRadius / 2
        #expect(panel.minX >= expected.minX, "the panel starts at x \(panel.minX) pt, outside its frame")
        #expect(panel.minX <= expected.minX + flare, "the panel starts at x \(panel.minX) pt")
        #expect(panel.maxX <= expected.maxX, "the panel ends at x \(panel.maxX) pt, outside its frame")
        #expect(panel.maxX >= expected.maxX - flare, "the panel ends at x \(panel.maxX) pt")
        #expect(abs((panel.minX + panel.maxX) / 2 - expected.midX) <= 1,
                "the panel is centred at x \((panel.minX + panel.maxX) / 2) pt, expected \(expected.midX) pt")

        // And the cards are drawn inside it, not over the slack around it.
        let cards = try #require(scan(image, matches: Ink.isBlue), "no cards inside the panel")
        #expect(cards.minX >= expected.minX, "a card starts at x \(cards.minX) pt, left of the panel")
        #expect(cards.maxX <= expected.maxX, "a card ends at x \(cards.maxX) pt, right of the panel")
        #expect(cards.minY >= expected.minY, "a card starts at y \(cards.minY) pt, above the panel")
        #expect(cards.maxY <= expected.maxY, "a card ends at y \(cards.maxY) pt, below the panel")
    }

    /// The horizontal runs of blue ink, one per card: the dashed border spans each card's
    /// full width and the 8 pt gap between cards has nothing in it.
    static func cardRuns(_ image: CGImage, scale: CGFloat = 2) -> [(min: CGFloat, max: CGFloat)] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var blueColumns: [Bool] = Array(repeating: false, count: width)
        for y in 0..<height {
            for x in 0..<width where !blueColumns[x] {
                let offset = (y * width + x) * 4
                let alpha = CGFloat(pixels[offset + 3]) / 255
                guard alpha > 0.5 else { continue }
                let r = CGFloat(pixels[offset]) / 255 / alpha
                let g = CGFloat(pixels[offset + 1]) / 255 / alpha
                let b = CGFloat(pixels[offset + 2]) / 255 / alpha
                if Ink.isBlue(r, g, b) { blueColumns[x] = true }
            }
        }

        var runs: [(min: CGFloat, max: CGFloat)] = []
        var start: Int?
        // A run ends only after a clear stretch: the dashes leave one-pixel holes in the
        // top and bottom borders, and those are not gaps between cards.
        // 6 pt: wider than the 4 pt hole a dash leaves, narrower than the 8 pt gap
        // between two cards.
        let tolerance = Int(6 * scale)
        var lastSeen = -tolerance - 1
        for x in 0..<width {
            guard blueColumns[x] else { continue }
            if let begun = start, x - lastSeen > tolerance {
                runs.append((CGFloat(begun) / scale, CGFloat(lastSeen + 1) / scale))
                start = x
            } else if start == nil {
                start = x
            }
            lastSeen = x
        }
        if let begun = start {
            runs.append((CGFloat(begun) / scale, CGFloat(lastSeen + 1) / scale))
        }
        return runs
    }

    @Test("Two untargeted cards split the panel evenly")
    func twoCardsSplitFiftyFifty() throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        let geometry = try Self.geometry()
        harness.model.handle(.enteredHotRect)

        let image = try #require(try Self.renderZones(harness.model), "the renderer produced no bitmap")
        let runs = Self.cardRuns(image)
        try #require(runs.count == 2, "expected two card regions, found \(runs.count): \(runs)")

        let widths = runs.map { $0.max - $0.min }
        #expect(abs(widths[0] - widths[1]) <= 2,
                "untargeted cards measured \(widths[0]) and \(widths[1]) pt")
        // The cards are inset 14 from the panel's edges, and the panel from the window's.
        let panelLeft = Self.panelOrigin.x
        #expect(abs(runs[0].min - (panelLeft + ZoneLayout.inset)) <= 2,
                "the first card starts at \(runs[0].min - panelLeft) pt into the panel")
        #expect(abs(runs[1].min - runs[0].max - ZoneLayout.gap) <= 2,
                "the gap between the cards measured \(runs[1].min - runs[0].max) pt")

        // Vertically: the top dash clears the physical notch — the whole point of
        // `ZoneLayout.topInset` — and the bottom one keeps the panel's 14 pt inset.
        let band = try #require(scan(image, matches: Ink.isBlue), "no card ink at all")
        let panelTop = Self.panelOrigin.y
        #expect(band.minY - panelTop >= geometry.notchHeight,
                "the cards start at \(band.minY - panelTop) pt, under the \(geometry.notchHeight) pt notch")
        #expect(abs(band.minY - (panelTop + ZoneLayout.topInset)) <= 2,
                "the top dash is at \(band.minY - panelTop) pt into the panel, expected \(ZoneLayout.topInset) pt")
        let bottom = panelTop + ZoneLayout.panelSize.height - ZoneLayout.inset
        #expect(abs(band.maxY - bottom) <= 2,
                "the bottom dash is at \(band.maxY) pt, expected \(bottom) pt")
    }

    @Test("Targeting a card widens it to 65 % against the other's 35 %")
    func targetingWidensTheCard() throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        harness.model.handle(.enteredHotRect)
        // Panel points, origin top-left: the AirDrop card spans x 14…136.
        #expect(harness.model.targeted(at: CGPoint(x: 70, y: 70)) == .airDrop)

        let image = try #require(try Self.renderZones(harness.model), "the renderer produced no bitmap")
        let runs = Self.cardRuns(image)
        try #require(runs.count == 2, "expected two card regions, found \(runs.count): \(runs)")

        let widths = runs.map { $0.max - $0.min }
        let share = widths[0] / (widths[0] + widths[1])
        #expect(abs(share - 0.65) <= 0.04,
                "the targeted card took \(share * 100) % of the two (expected 65 %)")
    }

    @Test("The stash card's large fan fits between the notch and the card's bottom edge")
    func stashCardFanFitsInsideTheCard() async throws {
        // The card band lost 20 pt when it moved out from under the notch, and the 48 pt
        // fan over a 13 pt header is what has to fit in what is left of it.
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        try await harness.stash(["a.png", "b.png"])
        harness.model.handle(.enteredHotRect)

        let image = try #require(try Self.renderZones(harness.model), "the renderer produced no bitmap")
        let fan = try #require(scan(image, matches: Ink.isRed), "the stash card drew no thumbnails")
        // A 48 pt tile at 2× is 9216 device pixels; far under that means it was clipped.
        #expect(fan.count >= 6000, "only \(fan.count) thumbnail pixels rendered")
        let panelTop = Self.panelOrigin.y
        #expect(fan.minY >= panelTop + ZoneLayout.topInset,
                "the fan starts at \(fan.minY - panelTop) pt into the panel, above the card's top edge")
        #expect(fan.maxY <= panelTop + ZoneLayout.panelSize.height - ZoneLayout.inset,
                "the fan runs to \(fan.maxY - panelTop) pt into the panel, past the card's bottom edge")
    }

    @Test("A completed drag-out poofs the stash content away")
    func completedDragOutFadesTheStash() async throws {
        let harness = try RenderHarness()
        defer { harness.cleanUp() }
        try await harness.stash(["Screenshot.png"])

        let before = try #require(
            try Self.renderPeek(
                leading: AnyView(StashLeadingView(model: harness.model)),
                trailing: AnyView(Color.clear)
            ),
            "the renderer produced no bitmap"
        )
        #expect(scan(before, matches: Ink.isRed) != nil, "no thumbnail before the drag-out")

        harness.model.dragOutBegan()
        harness.model.dragOutEnded(completed: true)
        #expect(harness.model.dragOutPhase == .completed)

        let after = try #require(
            try Self.renderPeek(
                leading: AnyView(StashLeadingView(model: harness.model)),
                trailing: AnyView(Color.clear)
            ),
            "the renderer produced no bitmap"
        )
        // The poof's end state is opacity 0: whatever the animation is doing mid-flight,
        // a view rendered from scratch in this phase is already gone.
        #expect(scan(after, matches: Ink.isRed) == nil,
                "the stash is still drawn after the drag-out was accepted")
    }

    @Test("The AirDrop glyph draws something")
    func airDropGlyphRendersInk() throws {
        let image = try #require(
            Self.render(
                ZStack {
                    Color.black
                    AirDropGlyph().frame(width: AirDropGlyph.designSize, height: AirDropGlyph.designSize)
                }
            ),
            "the renderer produced no bitmap"
        )
        let region = try #require(scan(image, matches: Ink.isBlue), "the AirDrop glyph drew nothing")
        #expect(region.count >= 200, "only \(region.count) glyph pixels rendered")
        // Three arcs up to r 12.5 in the 28 pt design box: the ink has to be most of it.
        #expect(region.maxX - region.minX >= 18, "the glyph measured \(region.maxX - region.minX) pt across")
    }
}
