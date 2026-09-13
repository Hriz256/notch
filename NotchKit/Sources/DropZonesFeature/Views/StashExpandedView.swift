import DropZonesShared
import IslandCore
import SwiftUI

// MARK: - The row's arithmetic

/// Where the hover-expanded card puts its row of tiles.
///
/// Kept apart from the views so the numbers can be asserted without a renderer, and so the
/// one place that decides how many tiles fit is the one place the card's height is derived
/// from.
enum StashRowLayout {
    /// The side of one tile. Big enough to recognise a screenshot by, small enough that
    /// seven of them fit the card's width.
    static let tileSize: CGFloat = 40
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 6

    /// The most boxes the row ever draws, tiles and the "+N" chip together.
    ///
    /// The card is 380 pt wide (``DropZonesViewModel/stashExpandedSize``, the width of
    /// every other page). Seven 40 pt boxes with 8 pt between them come to 328, which
    /// leaves the 26 pt side margins the peek slots' centres sit on; an eighth (376 pt)
    /// would run into the island's rounded corners, so the seventh box becomes the chip.
    static let maximumBoxes = 7

    /// The gap between the peek row and the tiles.
    static let gapBelowNotch: CGFloat = 8
    /// The gap between the tiles and the caption, and the caption's own height.
    static let captionGap: CGFloat = 14
    static let captionHeight: CGFloat = 20

    /// How far a hovered tile rises, and how much it grows: enough to read as "this one",
    /// small enough that the row does not ripple.
    static let hoverLift: CGFloat = 6
    static let hoverScale: CGFloat = 1.06
    static let hoverResponse: Double = 0.25
    static let hoverDamping: Double = 0.7

    /// The scale a tile in the row grows in from. Below 1, unlike the settle card's 1.12:
    /// these boxes are not landing from a drop, they are unfolding with the card.
    static let entranceScale: CGFloat = 0.92
    /// Reduce Motion gets the same information without the movement: the hovered tile is
    /// the one that is *not* dimmed.
    static let restingOpacity: Double = 0.85

    /// The width `boxes` tiles take, gaps included.
    static func width(boxes: Int) -> CGFloat {
        guard boxes > 0 else { return 0 }
        return CGFloat(boxes) * tileSize + CGFloat(boxes - 1) * spacing
    }

    /// The card's content height: the peek row, the tiles and the caption.
    static func contentHeight(notchHeight: CGFloat) -> CGFloat {
        notchHeight + gapBelowNotch + tileSize + captionGap + captionHeight
    }

    /// What the row draws for `files`: the tiles, newest first, and how many files the
    /// "+N" chip stands for (`0` when every file has a tile).
    ///
    /// Newest first because `StashIndex` appends — the end of the array is the last drop,
    /// and the file the user just put in is the one they are most likely to want back.
    static func plan(files: [StashedFile]) -> (tiles: [StashedFile], overflow: Int) {
        let newestFirst = Array(files.reversed())
        guard newestFirst.count > maximumBoxes else { return (newestFirst, 0) }
        let shown = maximumBoxes - 1
        return (Array(newestFirst.prefix(shown)), newestFirst.count - shown)
    }
}

// MARK: - The card

/// The hover-expanded stash card: the peek's two slots unmoved, a row of the stashed files
/// under them, and a caption saying what the pile is worth.
///
/// The row is the point of the card. A fan of thumbnails says *how many* files are in the
/// stash but offers one handle for all of them, and pulling one particular file out of a
/// pile of overlapping tiles is guesswork; laid out in a row, each file is its own target,
/// lifts when the pointer is on it, and drags out on its own. This is a deliberate
/// departure from Seam, at the user's request.
///
/// The top row is a real `PeekRow` at the real notch size rather than a re-creation of it,
/// because "unmoved" is the whole point: hovering the island must add rows, not shuffle the
/// two things the user was already looking at. The card is 380 pt wide like every other
/// page, so the row is *wider* than the peek and its two slots slide outward to hug the
/// island's new edges — at the user's request, and the reason `PeekRow` is asked for the
/// slots rather than told where they are. `SurfaceView` pushes expanded content below the
/// notch — right for a panel, wrong for a card whose first row *is* the peek — so that
/// padding is cancelled here and the row lands back at the island's top edge.
struct StashExpandedView: View {
    let model: DropZonesViewModel

    @Environment(\.notchSize) private var notchSize

    var body: some View {
        VStack(spacing: 0) {
            PeekRow(
                leading: AnyView(StashLeadingView(model: model)),
                trailing: AnyView(StashTrailingView(model: model)),
                notch: notchSize
            )
            .frame(height: notchSize.height)

            StashThumbnailRow(model: model)
                .padding(.top, StashRowLayout.gapBelowNotch)

            caption
                .frame(height: StashRowLayout.captionHeight)
                .padding(.top, StashRowLayout.captionGap)
                .stashPoof(model)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, -notchSize.height)
        .dropZonesContextMenu(model)
    }

    private var caption: some View {
        HStack(spacing: 5) {
            Image(systemName: "tray.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.blue)
            Text(StashCaption.text(count: model.index.files.count, bytes: model.index.totalBytes))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.caption)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - The row

/// One tile per stashed file, centred under the notch, newest on the left.
struct StashThumbnailRow: View {
    let model: DropZonesViewModel

    var body: some View {
        let plan = StashRowLayout.plan(files: model.index.files)
        // The chip is one of the boxes that fans in, so it shares the count the stagger is
        // budgeted against rather than arriving on its own beat.
        let boxes = plan.tiles.count + (plan.overflow > 0 ? 1 : 0)
        HStack(spacing: StashRowLayout.spacing) {
            ForEach(Array(plan.tiles.enumerated()), id: \.element.id) { index, file in
                StashThumbnailTile(model: model, file: file)
                    .settleEntrance(
                        index: index,
                        count: boxes,
                        span: SettleMotion.rowSpan,
                        fromScale: StashRowLayout.entranceScale,
                        fades: true
                    )
            }
            if plan.overflow > 0 {
                StashOverflowChip(count: plan.overflow)
                    .settleEntrance(
                        index: plan.tiles.count,
                        count: boxes,
                        span: SettleMotion.rowSpan,
                        fromScale: StashRowLayout.entranceScale,
                        fades: true
                    )
            }
        }
        .frame(height: StashRowLayout.tileSize)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// One stashed file in the row: a tile that lifts under the pointer and drags out alone.
///
/// The drag handle is laid over the tile at its *resting* frame rather than over the lifted
/// one: the lift is a visual offset, and a pointer that is hovering is by definition inside
/// the resting frame, so the handle is always under the cursor that is about to press.
private struct StashThumbnailTile: View {
    let model: DropZonesViewModel
    let file: StashedFile

    @Environment(\.stashDragEnabled) private var isDraggable
    @State private var isHovered = false

    var body: some View {
        ThumbnailCard(
            thumbnail: model.thumbnails[file.id],
            size: StashRowLayout.tileSize,
            cornerRadius: StashRowLayout.cornerRadius
        )
        .scaleEffect(scale)
        .offset(y: lift)
        .opacity(opacity)
        .animation(hoverAnimation, value: isHovered)
        // As in the peek: an overlay rather than a host, so the tile stays SwiftUI all the
        // way down and the right-click menu below still opens.
        .overlay {
            if isDraggable {
                StashDragSource(
                    files: [file],
                    store: model.store,
                    promises: model.promises,
                    // Only a real preview: a file QuickLook had nothing for has the
                    // system icon in its `Thumbnail`, and the drag draws its own at 32 pt.
                    thumbnail: { model.thumbnails[$0.id].flatMap { $0.hasPreview ? $0.image : nil } },
                    onBegan: { model.dragOutBegan() },
                    onEnded: { model.dragOutEnded(completed: $0, files: .single(file.id)) }
                )
            }
        }
        .onHover { isHovered = $0 }
        .filePoof(isPoofing: model.poofingFileIDs.contains(file.id))
        .dropZonesContextMenu(model, removing: file)
        .accessibilityLabel(file.name)
    }

    private var isLifted: Bool { isHovered && !MotionPreference.isReduced }

    private var lift: CGFloat { isLifted ? -StashRowLayout.hoverLift : 0 }
    private var scale: CGFloat { isLifted ? StashRowLayout.hoverScale : 1 }

    /// Reduce Motion swaps the lift for a brightness difference: every tile sits at
    /// ``StashRowLayout/restingOpacity`` and the hovered one comes up to full.
    private var opacity: Double {
        guard MotionPreference.isReduced else { return 1 }
        return isHovered ? 1 : StashRowLayout.restingOpacity
    }

    private var hoverAnimation: Animation? {
        MotionPreference.isReduced
            ? .linear(duration: 0.1)
            : .spring(response: StashRowLayout.hoverResponse, dampingFraction: StashRowLayout.hoverDamping)
    }
}

/// The files the row had no room for, as a count.
///
/// Not draggable and not a target: it is the row's way of saying "and this many more",
/// exactly as the count circle does for the fan.
struct StashOverflowChip: View {
    let count: Int

    static let fontSize: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: StashRowLayout.cornerRadius, style: .continuous)
            .fill(Palette.cardFill)
            .frame(width: StashRowLayout.tileSize, height: StashRowLayout.tileSize)
            .overlay {
                Text("+\(count)")
                    .font(.system(size: Self.fontSize, weight: .semibold))
                    .foregroundStyle(Palette.blue)
                    .monospacedDigit()
            }
            .accessibilityLabel("\(count) more file\(count == 1 ? "" : "s") stashed")
    }
}

// MARK: - One tile's poof

/// Shrinks and fades a single tile once its file has been taken out of the stash.
///
/// The whole-card `StashPoof` says "the stash left"; this says "that file left", which is
/// the only difference the user can see between dragging one tile out and dragging the fan.
private struct FilePoof: ViewModifier {
    let isPoofing: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPoofing && !MotionPreference.isReduced ? PoofTokens.scale : 1)
            .opacity(isPoofing ? 0 : 1)
            .animation(.easeOut(duration: PoofTokens.duration), value: isPoofing)
    }
}

extension View {
    func filePoof(isPoofing: Bool) -> some View {
        modifier(FilePoof(isPoofing: isPoofing))
    }
}
