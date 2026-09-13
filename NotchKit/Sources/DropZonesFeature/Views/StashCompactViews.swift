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
                    promises: model.promises,
                    thumbnail: { model.thumbnails[$0.id]?.image },
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

    private var isPoofing: Bool { model.dragOutPhase == .completed }

    func body(content: Content) -> some View {
        content
            // Reduce Motion keeps the fade and drops the shrink: the card still leaves
            // visibly, nothing moves.
            .scaleEffect(isPoofing && !MotionPreference.isReduced ? PoofTokens.scale : 1)
            .opacity(isPoofing ? 0 : 1)
            .animation(.easeOut(duration: PoofTokens.duration), value: isPoofing)
    }
}

/// The one shape a poof has, whether the whole card is leaving or a single tile is.
///
/// Spec §3.2: the poof is the beat between a drag-out being accepted and the files it took
/// disappearing from the island.
enum PoofTokens {
    static let duration: Double = 0.25
    static let scale: CGFloat = 0.6
}

extension View {
    func stashPoof(_ model: DropZonesViewModel) -> some View {
        modifier(StashPoof(model: model))
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
