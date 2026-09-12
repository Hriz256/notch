import AppKit
import DropZonesShared
import IslandCore
import SwiftUI

/// The zones panel, drawn by the drop catcher's own window instead of by the island.
///
/// Why here and not there: the island lives in a private SkyLight space that composites
/// above the system's drag-image window, so anything it draws hides the thumbnail in the
/// user's hand — and moving the window into the active user space for the drag does not
/// change that (measured on macOS 26.5, commit e1e8b4e). The catcher's window is an
/// ordinary-space one, so the drag image draws over it the way it does in Seam; it
/// already had to exist to receive the drop, so it draws the panel too, and the island
/// is suppressed to the bare notch underneath (``IslandPresenting/setSurfaceSuppressed(_:)``).
///
/// Geometry: the catcher's frame is the panel's rect grown by ``slack`` on the left,
/// right and bottom only (never above the screen, which AppKit would push back down),
/// so the panel is pinned to this view's top edge and centred across its width — which
/// puts its top edge on the screen's top edge and its centre on the notch's, exactly
/// where the island's expanded panel used to be.
///
/// Motion: the black shape grows out of the notch and shrinks back into it on the
/// island's own curves, so the hand-over in both directions is two black shapes of the
/// same size over the same notch. The cards fade with the island's content curves. There
/// is no `IslandFrame` clamp here — the shape is never smaller than the notch it starts
/// at, and it is not the island, so an undershoot cannot expose the hardware's edges.
struct ZonesPanelView: View {
    /// Read for ``DropZonesViewModel/isZonesShown`` (the whole state machine of this
    /// view) and handed to `ZonesView`, which draws the cards.
    let model: DropZonesViewModel
    /// The physical notch: where the shape grows from and shrinks back to.
    let notchSize: CGSize
    /// How far the catcher's window extends past the panel on every side.
    let slack: CGFloat
    let choreographer: TransitionChoreographer

    /// The expanded panel's corners, matching `IslandLayout.resolve(state: .expanded, …)`
    /// so the shape the island used to draw and the one drawn here are the same shape.
    static let topRadius: CGFloat = 12
    static let bottomRadius: CGFloat = 24

    @MainActor
    init(
        model: DropZonesViewModel,
        notchSize: CGSize = NotchSizeKey.defaultValue,
        slack: CGFloat = DropZonesFeature.catcherSlack,
        choreographer: TransitionChoreographer = .current()
    ) {
        self.model = model
        self.notchSize = notchSize
        self.slack = slack
        self.choreographer = choreographer
    }

    var body: some View {
        // Read straight off the model rather than mirrored into `@State`: the window is
        // ordered in *after* the flag flips, so a state seeded in `onAppear` would be a
        // frame late in the running app and simply absent in a render test, which never
        // runs `onAppear` at all.
        let shown = model.isZonesShown
        let size = shown ? ZoneLayout.panelSize : notchSize
        let shape = NotchShape(topRadius: Self.topRadius, bottomRadius: Self.bottomRadius)

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                ZonesView(model: model)
                    .frame(
                        width: ZoneLayout.panelSize.width,
                        height: ZoneLayout.panelSize.height,
                        alignment: .top
                    )
                    .opacity(shown ? 1 : 0)
                    .animation(shown ? choreographer.contentIn : choreographer.contentOut, value: shown)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            // The cards are laid out at the panel's full size whatever the shape is
            // doing, so the clip is what makes them appear out of the notch rather than
            // hanging outside it mid-animation.
            .clipShape(shape)
            .animation(shown ? choreographer.geometry : choreographer.collapseGeometry, value: shown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Belt and braces with ``PanelHostingView``: nothing in here is clickable, and
        // the window it lives in is over the menu bar.
        .allowsHitTesting(false)
    }
}

/// An `NSHostingView` that is invisible to the mouse and to drag routing.
///
/// `hitTest` answering `nil` sends every mouse event — and every drag hit test — past it
/// to the `DropCatcherView` it sits in, which is the view registered for the pasteboard
/// types. Without it the panel would be a 320×180 view over the menu bar that swallows
/// clicks for as long as a drag is in the air.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PanelHostingView is not loaded from a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
