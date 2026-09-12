import AppKit
import CoreGraphics
import DropZonesShared
import Foundation
import Testing

@testable import DropZonesFeature
@testable import IslandCore

/// The numbers and strings the drop-zone views are built from.
///
/// Everything here is checkable without a renderer; `StashLayoutRenderTests` covers the
/// half that only a bitmap can answer.
@MainActor
@Suite("Drop-zone view values")
struct DropZonesViewsTests {

    // MARK: - Card chrome

    @Test("Each zone card draws the symbol the spec names, and AirDrop draws none")
    func cardSymbols() {
        // AirDrop has no public SF Symbol, which is why `AirDropGlyph` exists.
        #expect(ZoneCardView.symbol(for: .airDrop) == nil)
        #expect(ZoneCardView.symbol(for: .stash) == "tray.and.arrow.down.fill")
        #expect(ZoneCardView.symbol(for: .addToStash) == "plus.rectangle.on.rectangle")
        #expect(ZoneCardView.symbol(for: .replaceStash) == "arrow.triangle.2.circlepath")
    }

    @Test("The card chrome is the dashed blue rectangle the design asks for")
    func cardChrome() {
        #expect(ZoneCardView.cornerRadius == 12)
        #expect(ZoneCardView.strokeWidth == 1.5)
        #expect(ZoneCardView.dash == [4, 4])
        #expect(ZoneCardView.iconSize == 26)
        #expect(ZoneCardView.labelSize == 12)
        #expect(ZoneCardView.labelSpacing == 8)
        #expect(ZoneCardView.headerSize == 13)
    }

    @Test("The label on each card is the shared title, so the panel and the menus agree")
    func cardLabels() {
        #expect(ZoneTitle.label(.airDrop, fileCount: 0) == "AirDrop")
        #expect(ZoneTitle.label(.stash, fileCount: 0) == "File Stash")
        #expect(ZoneTitle.label(.stash, fileCount: 1) == "1 File")
        #expect(ZoneTitle.label(.stash, fileCount: 3) == "3 Files")
        #expect(ZoneTitle.label(.addToStash, fileCount: 2) == "Add to Stash")
        #expect(ZoneTitle.label(.replaceStash, fileCount: 2) == "Replace Stash")
    }

    @Test("The stash caption is the count and the size, as the hover card shows it")
    func captionText() {
        // The size itself is `ByteCountFormatter`'s, and its decimal separator follows the
        // user's locale — the assertion is about the count, the noun and the separator.
        #expect(StashCaption.text(count: 1, bytes: 89_000)
            == "1 file \u{00B7} \(ByteFormatting.fileSize(89_000))")
        #expect(StashCaption.text(count: 3, bytes: 1_200_000)
            == "3 files \u{00B7} \(ByteFormatting.fileSize(1_200_000))")
        #expect(ByteFormatting.fileSize(89_000) == "89 KB")
    }

    // MARK: - The AirDrop glyph

    @Test("The AirDrop glyph is three arcs around a dot, with a gap at the bottom")
    func airDropGeometry() {
        #expect(AirDropGlyph.designSize == 28)
        #expect(AirDropGlyph.waveRadii == [5.5, 9, 12.5])
        #expect(AirDropGlyph.dotRadius == 2.2)
        #expect(AirDropGlyph.lineWidth == 1.5)
        // 125° → 415° leaves 70° open, centred on 90° — straight down in SwiftUI's y-down
        // space, which is where the dot sits.
        #expect(AirDropGlyph.endAngle - AirDropGlyph.startAngle == 290)
        let gapCentre = (AirDropGlyph.startAngle + AirDropGlyph.endAngle) / 2 - 180
        #expect(gapCentre == 90)
    }

    // MARK: - The thumbnail fan

    @Test("The two stack presets are the sizes the spec names")
    func stackTokens() {
        let compact = ThumbnailStackTokens.compact
        #expect(compact.thumbSize == 22)
        #expect(compact.rotations == [-9, 0, 9])
        #expect(compact.scales == [1, 0.94, 0.88])
        #expect(compact.cornerRadius == 4)

        let large = ThumbnailStackTokens.large
        #expect(large.thumbSize == 48)
        #expect(large.rotations == [-10, 0, 10])
        #expect(large.scales == [1, 0.94, 0.88])
        #expect(large.cornerRadius == 6)

        #expect(ThumbnailStackTokens.depthOffset == 2)
    }

    @Test("The newest file is upright on top and the ones behind it lean out either way")
    func fanAngles() {
        let tokens = ThumbnailStackTokens.compact
        #expect(tokens.rotation(depth: 0) == 0)
        #expect(tokens.rotation(depth: 1) == -9)
        #expect(tokens.rotation(depth: 2) == 9)
        // A fourth card is never drawn, but asking must not trap.
        #expect(tokens.rotation(depth: 5) == 9)

        #expect(tokens.scale(depth: 0) == 1)
        #expect(tokens.scale(depth: 1) == 0.94)
        #expect(tokens.scale(depth: 2) == 0.88)
        #expect(tokens.scale(depth: 9) == 0.88)
    }

    @Test("The stack never draws more than three cards")
    func stackIsCappedAtThree() {
        #expect(ThumbnailStack.maximumCards == 3)
    }

    // MARK: - The count badge and the caption row

    @Test("The count circle is the 18 pt outlined badge from the reference")
    func countCircle() {
        #expect(FileCountCircle.diameter == 18)
        #expect(FileCountCircle.lineWidth == 1.5)
    }

    @Test("The caption row's centre lands 24 pt below the row of tiles")
    func captionPosition() {
        // The row is laid out under the tiles, so its centre is `gap + height / 2` below
        // their bottom edge.
        let centre = StashRowLayout.captionGap + StashRowLayout.captionHeight / 2
        #expect(centre == 24)
    }

    // MARK: - The row of tiles

    @Test("The row's tiles are the 40 pt cards the design asks for")
    func rowTokens() {
        #expect(StashRowLayout.tileSize == 40)
        #expect(StashRowLayout.spacing == 8)
        #expect(StashRowLayout.cornerRadius == 6)
        #expect(StashRowLayout.gapBelowNotch == 8)
        #expect(StashRowLayout.hoverLift == 6)
        #expect(StashRowLayout.hoverScale == 1.06)
    }

    @Test("Seven 40 pt boxes and their gaps fit the 380 pt card with its corner margins, eight do not")
    func rowFitsTheCardsWidth() {
        // The card is as wide as the Music and Code pages; the row keeps clear of the
        // 24 pt bottom corners on each side.
        let usable = DropZonesViewModel.stashExpandedSize.width - 2 * 24
        #expect(StashRowLayout.width(boxes: StashRowLayout.maximumBoxes) == 328)
        #expect(StashRowLayout.width(boxes: StashRowLayout.maximumBoxes) <= usable)
        #expect(StashRowLayout.width(boxes: StashRowLayout.maximumBoxes + 1) > usable,
                "one more box would run into the corners, which is why the last one is the chip")
        #expect(StashRowLayout.width(boxes: 1) == StashRowLayout.tileSize)
        #expect(StashRowLayout.width(boxes: 0) == 0)
    }

    @Test("The card is 124 pt tall: the peek row, the tiles and the caption")
    func cardHeight() {
        // A 32 pt notch, the standard one the render tests use.
        #expect(StashRowLayout.contentHeight(notchHeight: 32) == 114)
        #expect(StashRowLayout.contentHeight(notchHeight: 32) <= DropZonesViewModel.stashExpandedSize.height)
        #expect(DropZonesViewModel.stashExpandedSize == CGSize(width: 380, height: 124))
    }

    @Test("The row shows the newest file first and every file while they fit")
    func rowOrder() {
        let files = (1...4).map { StashedFile(name: "\($0).txt", storedPath: "/tmp/\($0)", bytes: 1) }
        let plan = StashRowLayout.plan(files: files)
        // `StashIndex` appends, so the end of the array is the newest drop.
        #expect(plan.tiles.map(\.name) == ["4.txt", "3.txt", "2.txt", "1.txt"])
        #expect(plan.overflow == 0)
    }

    @Test("Past the sixth box the row ends in a chip counting what it could not show")
    func rowOverflow() {
        func plan(_ count: Int) -> (tiles: [StashedFile], overflow: Int) {
            StashRowLayout.plan(
                files: (1...count).map { StashedFile(name: "\($0).txt", storedPath: "/tmp/\($0)", bytes: 1) }
            )
        }
        // Exactly full: seven files, seven tiles, no chip.
        #expect(plan(7).tiles.count == 7)
        #expect(plan(7).overflow == 0)
        // Eight: six tiles and a chip standing for the two that did not fit.
        #expect(plan(8).tiles.map(\.name) == ["8.txt", "7.txt", "6.txt", "5.txt", "4.txt", "3.txt"])
        #expect(plan(8).overflow == 2)
        // Whatever the count, the row is never more than seven boxes wide.
        #expect(plan(40).tiles.count + 1 == StashRowLayout.maximumBoxes)
        #expect(plan(40).overflow == 34)
    }

    @Test("An empty stash draws no row at all")
    func emptyRow() {
        let plan = StashRowLayout.plan(files: [])
        #expect(plan.tiles.isEmpty)
        #expect(plan.overflow == 0)
    }

    // MARK: - Drag out

    @Test("A promise advertises the file's own type, and falls back rather than refusing")
    func promiseFileTypes() {
        func type(_ name: String) -> String {
            DragSourceView.fileType(for: StashedFile(name: name, storedPath: "/tmp/\(name)", bytes: 1))
        }
        #expect(type("Screenshot.png") == "public.png")
        #expect(type("notes.txt") == "public.plain-text")
        // No extension at all: there is nothing to look a type up by, so the promise
        // offers raw bytes rather than refusing to drag.
        #expect(type("Makefile") == "public.data")
    }

    @Test("A promise provider keeps its delegate alive after the drag has let go of it")
    func promiseProviderOwnsItsDelegate() {
        // `NSFilePromiseProvider.delegate` is weak, and Finder writes the promise on its
        // own schedule — routinely after `draggingSession(_:endedAt:operation:)` has run.
        // If the session were the only owner, the provider would be delegate-less by the
        // time the receiver asked for the bytes and the file would never be written.
        let store = StashStore(
            baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DropZonesViewsTests-\(UUID().uuidString)")
        )
        var delegate: StashFilePromiseDelegate? = StashFilePromiseDelegate(store: store, promises: DragOutPromiseTracker())
        let provider = StashFilePromiseProvider(
            file: StashedFile(name: "a.png", storedPath: "/tmp/a.png", bytes: 1),
            fileType: "public.png",
            delegate: delegate!
        )
        // Every other reference is gone — this is the drag ending.
        delegate = nil

        // A weak property reads `nil` the moment its object is deallocated, so this is a
        // statement about the delegate's lifetime, not about a stale pointer.
        #expect(provider.delegate != nil, "the promise lost its delegate when the drag ended")
        #expect(provider.file.name == "a.png")
        #expect(provider.fileType == "public.png")
    }

    @Test("The drag image is the 32 pt cascade the spec describes")
    func dragImageCascade() {
        #expect(DragSourceView.iconSide == 32)
        #expect(DragSourceView.dragThreshold == 4)
        #expect(DragOutPolicy.dragImageOffset(index: 0) == CGPoint(x: 0, y: 0))
        // Right and *up-screen*: the offsets are read in `DragSourceView`'s coordinate
        // space, which the view flips so that −y is up, as `setDraggingFrame` takes its
        // rect in the source view's own coordinates.
        #expect(DragOutPolicy.dragImageOffset(index: 2) == CGPoint(x: 8, y: -8))
        #expect(DragSourceView().isFlipped)
    }
}
