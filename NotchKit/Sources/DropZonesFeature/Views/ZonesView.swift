import DropZonesShared
import IslandCore
import SwiftUI

/// The panel the island becomes while a file drag is near the notch: one card per zone,
/// laid out by `ZoneLayout`, and after a drop the single full-width settle card.
///
/// Every card is placed at its `ZoneLayout.Slot.frame` rather than by a stack's own
/// spacing. The drop catcher hit-tests those exact rects, so a card drawn anywhere else
/// would mean a drop landing on a zone the user was not pointing at — the one bug in this
/// feature the user could never diagnose.
///
/// The panel is drawn in **island** coordinates: `SurfaceView` pushes expanded content
/// below the notch so features never draw where the hardware hides them, but the panel's
/// coordinate space has to stay the island's for the hit test to agree with it, so that
/// padding is cancelled here. What keeps the cards out from under the hardware is
/// `ZoneLayout.topInset`, which starts them 2 pt below the notch's bottom edge — exactly
/// where the reference frames put the top dash.
struct ZonesView: View {
    let model: DropZonesViewModel

    @Environment(\.notchSize) private var notchSize

    /// The panel's geometry spring (spec §3.3): fast enough that widening the targeted
    /// card keeps up with the cursor, damped enough not to wobble under it.
    static let geometry = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cards, id: \.zone) { slot in
                card(for: slot)
                    .frame(width: slot.frame.width, height: slot.frame.height)
                    .position(x: slot.frame.midX, y: slot.frame.midY)
                    .transition(cardTransition)
            }
        }
        .frame(width: ZoneLayout.panelSize.width, height: ZoneLayout.panelSize.height, alignment: .topLeading)
        .padding(.top, -notchSize.height)
        .animation(ZonesView.geometry, value: model.animationState)
        .dropZonesContextMenu(model)
    }

    // MARK: - What to draw

    /// After a drop the panel stops being a choice and becomes a receipt: one card, the
    /// full width of the content rect, holding what just landed.
    private var isSettling: Bool {
        model.phase == .settling || model.pendingURLs != nil
    }

    /// The card rect comes from `ZoneLayout` rather than from insets spelled out again
    /// here: the settle card lands exactly where the stash card the user just dropped on
    /// was, so the panel reads as that card growing to full width.
    private var settleSlot: ZoneLayout.Slot {
        ZoneLayout.Slot(zone: .stash, frame: ZoneLayout.contentRect, isTargeted: false)
    }

    private var cards: [ZoneLayout.Slot] {
        isSettling ? [settleSlot] : model.layout.slots
    }

    /// What the settle card counts.
    ///
    /// Until the copy finishes there is no index to count, so the card counts the files
    /// still in flight — the user dropped three files and must see "3 Files" at once, not
    /// "0 Files" and then a jump. The moment the copy lands, the index is the truth and
    /// the pending list is stale: a drop that *replaced* a fuller stash must not keep
    /// showing the old, larger count, which is what taking the larger of the two did.
    private var settleCount: Int {
        model.pendingURLs?.count ?? model.index.files.count
    }

    @ViewBuilder
    private func card(for slot: ZoneLayout.Slot) -> some View {
        ZoneCardView(
            slot: slot,
            fileCount: isSettling ? settleCount : model.index.files.count,
            files: model.index.files,
            thumbnails: model.thumbnails,
            otherTargeted: model.targeted != nil && !slot.isTargeted,
            isEntering: isSettling
        )
    }

    // MARK: - Motion

    /// Cards fade and grow into place. Reduce Motion keeps the fade and drops the scale:
    /// the panel still tells the user a card arrived, without anything moving.
    private var cardTransition: AnyTransition {
        MotionPreference.isReduced ? .opacity : .opacity.combined(with: .scale(scale: 0.95))
    }
}
