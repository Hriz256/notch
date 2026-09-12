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
/// padding is cancelled here. The top 18 pt of each card does sit behind the notch as a
/// result — which is exactly what the reference frames show, a card that starts at the
/// notch's bottom edge.
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

    private var settleSlot: ZoneLayout.Slot {
        let inset = ZoneLayout.inset
        return ZoneLayout.Slot(
            zone: .stash,
            frame: CGRect(
                x: inset,
                y: inset,
                width: ZoneLayout.panelSize.width - 2 * inset,
                height: ZoneLayout.panelSize.height - 2 * inset
            ),
            isTargeted: false
        )
    }

    private var cards: [ZoneLayout.Slot] {
        isSettling ? [settleSlot] : model.layout.slots
    }

    /// What the settle card counts. The stash index catches up a moment after the drop, so
    /// until it does the card counts the files still being copied — the user dropped three
    /// files and must see "3 Files" at once, not "0 Files" and then a jump.
    private var settleCount: Int {
        max(model.pendingURLs?.count ?? 0, model.index.files.count)
    }

    @ViewBuilder
    private func card(for slot: ZoneLayout.Slot) -> some View {
        ZoneCardView(
            slot: slot,
            fileCount: isSettling ? settleCount : model.index.files.count,
            files: model.index.files,
            thumbnails: model.thumbnails,
            otherTargeted: model.targeted != nil && !slot.isTargeted,
            topInset: max(0, notchSize.height - slot.frame.minY),
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
