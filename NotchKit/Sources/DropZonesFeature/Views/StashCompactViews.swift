import DropZonesShared
import IslandCore
import SwiftUI

/// The island's leading peek slot while files are stashed: the fan of thumbnails, and the
/// handle the whole stash is dragged out by.
///
/// The thumbnails *are* the affordance — there is no button and no chrome next to the
/// notch — so the same 30 pt of pixels have to say what is in the stash and be grabbable.
struct StashLeadingView: View {
    let model: DropZonesViewModel

    @Environment(\.stashDragEnabled) private var isDraggable

    var body: some View {
        ThumbnailStack(
            files: model.index.files,
            thumbnails: model.thumbnails,
            tokens: .compact
        )
        // The drag handle is laid *over* the fan rather than hosting it, so the thumbnails
        // stay SwiftUI all the way down and the menu below still opens on a right-click.
        .overlay {
            if isDraggable {
                StashDragSource(
                    files: model.index.files,
                    store: model.store,
                    observer: model.dragObserver,
                    onBegan: { model.dragOutBegan() },
                    onEnded: { model.dragOutEnded(completed: $0) }
                )
            }
        }
        .stashPoof(model)
        .stashSlot()
        .dropZonesContextMenu(model)
    }
}

/// The island's trailing peek slot: how many files are in there.
struct StashTrailingView: View {
    let model: DropZonesViewModel

    var body: some View {
        FileCountCircle(count: model.index.files.count)
            .stashPoof(model)
            .stashSlot()
            .dropZonesContextMenu(model)
    }
}

/// Shrinks and fades the stash's content once a drag out of it has been accepted.
///
/// The files are gone from the island's point of view the moment the receiver takes them,
/// but the card is dismissed a quarter of a second later so the user sees *which* card
/// left. Without the poof the island simply cuts to the next card and the drop reads as
/// having gone nowhere.
private struct StashPoof: ViewModifier {
    let model: DropZonesViewModel

    /// Spec §3.2: the poof is the beat between a completed drag-out and the stash clearing.
    static let duration: Double = 0.25
    static let scale: CGFloat = 0.6

    private var isPoofing: Bool { model.dragOutPhase == .completed }

    func body(content: Content) -> some View {
        content
            // Reduce Motion keeps the fade and drops the shrink: the card still leaves
            // visibly, nothing moves.
            .scaleEffect(isPoofing && !MotionPreference.isReduced ? Self.scale : 1)
            .opacity(isPoofing ? 0 : 1)
            .animation(.easeOut(duration: Self.duration), value: isPoofing)
    }
}

extension View {
    func stashPoof(_ model: DropZonesViewModel) -> some View {
        modifier(StashPoof(model: model))
    }
}

/// The hover-expanded stash card: the peek's two slots, unmoved, over a caption saying
/// what the stack is worth.
///
/// The top row is a real `PeekRow` at the real notch size rather than a re-creation of it,
/// because "unmoved" is the whole point: hovering the island must add a line, not shuffle
/// the two things the user was already looking at. `SurfaceView` pushes expanded content
/// below the notch — right for a panel, wrong for a card whose first row *is* the peek —
/// so that padding is cancelled here and the row lands back at the island's top edge.
struct StashExpandedView: View {
    let model: DropZonesViewModel

    @Environment(\.notchSize) private var notchSize

    /// The caption row's height, and the gap above it. Together with the notch they put
    /// the row's centre 26 pt below the notch's bottom edge (spec §3.3).
    static let captionHeight: CGFloat = 20
    static let captionGap: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            PeekRow(
                leading: AnyView(StashLeadingView(model: model)),
                trailing: AnyView(StashTrailingView(model: model)),
                notch: notchSize
            )
            .frame(height: notchSize.height)

            caption
                .frame(height: Self.captionHeight)
                .padding(.top, Self.captionGap)
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

/// Whether the thumbnails carry the AppKit drag handle.
///
/// On everywhere but the render tests. `ImageRenderer` cannot draw an `NSViewRepresentable`
/// — it paints an "unsupported" placeholder over the whole of its frame — so a test that
/// measured the stack through the handle would be measuring the placeholder, and would go
/// on passing however wrong the thumbnails underneath became. Switching the handle off is
/// sound because it is an overlay: it contributes nothing to layout either way.
struct StashDragEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var stashDragEnabled: Bool {
        get { self[StashDragEnabledKey.self] }
        set { self[StashDragEnabledKey.self] = newValue }
    }
}

extension View {
    /// Centres a stash glyph in the 56 pt the surface gives a peek slot, vertically as well
    /// as horizontally — the same rule the Code island's slots follow, so the two features'
    /// cards line up with each other.
    func stashSlot() -> some View {
        frame(width: IslandLayout.peekSlotWidth, alignment: .center)
            .frame(maxHeight: .infinity, alignment: .center)
    }
}
