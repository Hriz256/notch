import AppKit
import DropZonesShared
import SwiftUI

// MARK: - One tile

/// One stashed file as a rounded tile.
///
/// The image is fitted rather than filled: a screenshot is wider than it is tall, and
/// cropping it to a square throws away the part that tells the user which screenshot it
/// is. The black backing is what makes the leftover letterbox read as a card rather than
/// as a hole in the island — except for a file QuickLook could not preview, where the
/// system icon is already a shape of its own and a black square behind it only boxes it in.
struct ThumbnailCard: View {
    let thumbnail: Thumbnail?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .frame(width: size, height: size)
            .background(hasBacking ? Color.black : Color.clear)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.thumbStroke, lineWidth: 1))
    }

    /// A preview fills its tile; an icon and the placeholder do not, so they get no black
    /// square behind them.
    private var hasBacking: Bool { thumbnail?.hasPreview ?? false }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            Image(nsImage: thumbnail.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // The thumbnail is generated after the drop lands, so for the first frames of
            // every settle there is a file with no image yet. A glyph keeps the stack the
            // right shape instead of letting it pop in a tile late.
            Image(systemName: "doc.fill")
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(Palette.blue.opacity(0.7))
        }
    }
}

// MARK: - The fan

/// The sizes and angles one thumbnail stack is drawn with.
///
/// Two presets, because the stack appears at two very different sizes — 22 pt in the peek
/// slot next to the notch, 48 pt inside the settle card — and every number except the
/// angles has to change between them.
struct ThumbnailStackTokens: Equatable {
    /// The side of each square tile.
    var thumbSize: CGFloat
    /// The angles of the fan in degrees, in visual order: leaning left, upright, leaning
    /// right. See ``rotation(depth:)`` for which card takes which.
    var rotations: [Double]
    /// How much each card behind the top one shrinks.
    var scales: [CGFloat]
    var cornerRadius: CGFloat

    /// The peek slot and the hover-expanded card's top row.
    static let compact = ThumbnailStackTokens(
        thumbSize: 22,
        rotations: [-9, 0, 9],
        scales: [1, 0.94, 0.88],
        cornerRadius: 4
    )

    /// The stash zone card and the settle card.
    static let large = ThumbnailStackTokens(
        thumbSize: 48,
        rotations: [-10, 0, 10],
        scales: [1, 0.94, 0.88],
        cornerRadius: 6
    )

    /// How far each card behind the top one is nudged down and right.
    static let depthOffset: CGFloat = 2

    /// The angle for the card `depth` layers below the top one.
    ///
    /// The newest file sits upright in the middle of the fan and the ones behind it lean
    /// out to either side: the file the user just dropped is the one they want to
    /// recognise, so it is the one drawn straight and unobscured, and the lean is what
    /// makes two files read as two files at a glance rather than as one thick card.
    func rotation(depth: Int) -> Double {
        // Depth 0 takes the upright middle angle, depth 1 the left lean, depth 2 the right.
        let order = [1, 0, 2]
        guard !rotations.isEmpty else { return 0 }
        return rotations[min(order[min(depth, order.count - 1)], rotations.count - 1)]
    }

    func scale(depth: Int) -> CGFloat {
        guard !scales.isEmpty else { return 1 }
        return scales[min(depth, scales.count - 1)]
    }
}

/// Up to three stashed files fanned out, newest on top.
///
/// Three is the whole stack however many files are stashed: a fourth card adds no
/// information (the exact count is in the badge next to it) and at 22 pt the fan runs out
/// of slot. The count circle is the number; this is the picture.
struct ThumbnailStack: View {
    let files: [StashedFile]
    let thumbnails: [UUID: Thumbnail]
    var tokens: ThumbnailStackTokens = .compact
    /// Whether the tiles should play their entrance. Only the settle card asks for it.
    var isEntering = false

    /// Flipped once, on the first layout pass, so the entrance plays exactly once per
    /// appearance of the stack rather than on every model change that redraws it.
    @State private var hasSettled = false

    /// How many cards the fan ever shows.
    static let maximumCards = 3

    /// Newest first — `StashIndex` appends, so the end of the array is the newest drop.
    private var visible: [StashedFile] {
        Array(files.reversed().prefix(Self.maximumCards))
    }

    /// The box the fan needs: the tile plus the room the lean and the depth offsets take.
    private var side: CGFloat {
        tokens.thumbSize + 2 * ThumbnailStackTokens.depthOffset + 4
    }

    var body: some View {
        ZStack {
            // Painted back to front so the newest file ends up on top.
            ForEach(Array(visible.enumerated()).reversed(), id: \.element.id) { depth, file in
                ThumbnailCard(
                    thumbnail: thumbnails[file.id],
                    size: tokens.thumbSize,
                    cornerRadius: tokens.cornerRadius
                )
                .scaleEffect(tokens.scale(depth: depth))
                .rotationEffect(.degrees(tokens.rotation(depth: depth)))
                .offset(
                    x: ThumbnailStackTokens.depthOffset * CGFloat(depth),
                    y: ThumbnailStackTokens.depthOffset * CGFloat(depth)
                )
                .zIndex(Double(Self.maximumCards - depth))
            }
        }
        .frame(width: side, height: side)
        // The dropped files land at 1.12 and settle to 1 — the only motion in the stack,
        // and the first thing the user sees after letting go. Reduce Motion draws them
        // at rest instead; the rotations above are static in both cases.
        .scaleEffect(playsEntrance && !hasSettled ? 1.12 : 1)
        .animation(playsEntrance ? .easeOut(duration: 0.3) : nil, value: hasSettled)
        .onAppear { hasSettled = true }
    }

    private var playsEntrance: Bool {
        isEntering && !MotionPreference.isReduced
    }
}

// MARK: - The badge

/// The stash's file count, as a stroked blue circle in the peek's trailing slot.
///
/// Outlined rather than filled: it sits a few points from the notch's edge, and a solid
/// blue disc there reads as a notification badge — something wrong — rather than as a
/// count.
struct FileCountCircle: View {
    let count: Int

    static let diameter: CGFloat = 18
    static let lineWidth: CGFloat = 1.5

    var body: some View {
        Circle()
            .strokeBorder(Palette.blue, lineWidth: Self.lineWidth)
            .frame(width: Self.diameter, height: Self.diameter)
            .overlay {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.blue)
                    .monospacedDigit()
            }
            .accessibilityLabel("\(count) file\(count == 1 ? "" : "s") stashed")
    }
}

// MARK: - Motion

/// The one place Reduce Motion is read in this feature, mirroring `GlyphMotion` in the
/// Code island.
///
/// Read fresh each time rather than cached: the setting can change while the app runs, and
/// the cost is a single `NSWorkspace` property.
@MainActor
enum MotionPreference {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
