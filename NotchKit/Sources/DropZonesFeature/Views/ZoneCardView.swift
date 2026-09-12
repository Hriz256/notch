import DropZonesShared
import SwiftUI

/// One drop-zone card: the dashed rounded rectangle with its icon and label.
///
/// The card draws itself at whatever size it is given — `ZonesView` owns the geometry,
/// which comes from `ZoneLayout` so that the card the user sees and the rect the drop
/// catcher hit-tests are the same rect by construction.
///
/// Two contents, not two views: an empty stash card is an icon over a label like every
/// other card, and a stash card with files in it is a header over the thumbnails. Keeping
/// both here means the transition between them is a content change inside one card rather
/// than one card replacing another, which is what lets the settle animate instead of blink.
struct ZoneCardView: View {
    let slot: ZoneLayout.Slot
    /// How many files the card should say it holds. For the settle card this is the
    /// dropped count, which can run ahead of the stash by a frame or two.
    let fileCount: Int
    let files: [StashedFile]
    let thumbnails: [UUID: Thumbnail]
    /// Whether some *other* card is the drop target, which dims this one.
    var otherTargeted = false
    /// How much of the card's top the physical notch covers. The stash card's header has
    /// to clear it; a plain card's icon and label sit low enough not to care.
    var topInset: CGFloat = 0
    /// Whether the thumbnails should play their entrance — true for the settle card.
    var isEntering = false

    static let cornerRadius: CGFloat = 12
    static let strokeWidth: CGFloat = 1.5
    static let dash: [CGFloat] = [4, 4]
    static let iconSize: CGFloat = 26
    static let labelSize: CGFloat = 12
    /// The gap between a plain card's icon and its label.
    static let labelSpacing: CGFloat = 8
    /// The stash card's header, when it has files under it.
    static let headerSize: CGFloat = 13
    static let headerSpacing: CGFloat = 10

    /// The stash card shows its pile once there is one; every other card is always the
    /// icon-over-label form.
    private var showsThumbnails: Bool {
        slot.zone == .stash && fileCount > 0
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        ZStack {
            shape.fill(slot.isTargeted ? Palette.cardFillTargeted : Palette.cardFill)
            shape.strokeBorder(
                Palette.blue,
                style: StrokeStyle(lineWidth: Self.strokeWidth, dash: Self.dash)
            )
            content
        }
        .scaleEffect(slot.isTargeted && !MotionPreference.isReduced ? ZoneLayout.targetedScale : 1)
        // The untargeted cards stay fully drawn but recede, so the panel still reads as a
        // choice of two rather than as one card with something vague beside it.
        .opacity(otherTargeted ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ZoneTitle.label(slot.zone, fileCount: fileCount))
    }

    @ViewBuilder
    private var content: some View {
        if showsThumbnails {
            VStack(spacing: Self.headerSpacing) {
                header
                ThumbnailStack(
                    files: files,
                    thumbnails: thumbnails,
                    tokens: .large,
                    isEntering: isEntering
                )
            }
            // Centred in what the user can actually see: the top of the card is behind
            // the notch, and a header centred in the whole card would be hidden by it.
            .padding(.top, topInset)
        } else {
            VStack(spacing: Self.labelSpacing) {
                icon
                    .frame(width: Self.iconSize, height: Self.iconSize)
                Text(ZoneTitle.label(slot.zone, fileCount: fileCount))
                    .font(.system(size: Self.labelSize, weight: .semibold))
                    .foregroundStyle(Palette.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 6)
        }
    }

    /// The stash card's header once it has files: the tray and the count, in a row.
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: Self.symbol(for: .stash) ?? "tray.and.arrow.down.fill")
                .font(.system(size: Self.headerSize, weight: .semibold))
            Text(ZoneTitle.label(slot.zone, fileCount: fileCount))
                .font(.system(size: Self.headerSize, weight: .semibold))
        }
        .foregroundStyle(Palette.blue)
    }

    @ViewBuilder
    private var icon: some View {
        if let symbol = Self.symbol(for: slot.zone) {
            Image(systemName: symbol)
                .font(.system(size: Self.iconSize * 0.85, weight: .medium))
                .foregroundStyle(Palette.blue)
        } else {
            AirDropGlyph()
        }
    }

    /// The SF Symbol each card draws, or `nil` for AirDrop — which has no public symbol
    /// and is drawn by ``AirDropGlyph``.
    static func symbol(for zone: Zone) -> String? {
        switch zone {
        case .airDrop: nil
        case .stash: "tray.and.arrow.down.fill"
        case .addToStash: "plus.rectangle.on.rectangle"
        case .replaceStash: "arrow.triangle.2.circlepath"
        }
    }
}
