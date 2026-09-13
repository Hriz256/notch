import SwiftUI

/// Root SwiftUI view inside the surface window. Draws the black shape sized by
/// `IslandLayout` and hosts the current presentation's views.
///
/// `presenter` is a plain `let`: `IslandPresenter` is `@Observable`, so reading it
/// in `body` registers observation tracking without `@Bindable`, which is only
/// needed to derive `$` bindings.
public struct SurfaceView: View {
    private let presenter: IslandPresenter
    private let geometry: NotchGeometry
    /// A fixed choreography, when one was handed in. `nil` in the app, where the curves
    /// are resolved while drawing from the live Reduce Motion setting; tests and previews
    /// pin one so they do not depend on the machine they run on.
    private let pinnedChoreographer: TransitionChoreographer?
    /// `nil` whenever a choreography is pinned, so a test or a preview never reaches for
    /// the shared instance and its workspace observer.
    private let motion: MotionSettings?

    /// The curves in force for this draw. Reading ``MotionSettings/isReduced`` here is
    /// what makes Reduce Motion live: the setting changing re-draws the island, and the
    /// island picks up the reduced curves without the window being rebuilt.
    private var choreographer: TransitionChoreographer {
        if let pinnedChoreographer { return pinnedChoreographer }
        return .resolved(isReduced: motion?.isReduced ?? false)
    }

    /// The island as `body` last drew it. Written only from `onChange`, which runs after
    /// `body`, so the value read while building `body` is genuinely the previous one.
    ///
    /// Three things are decided by comparing it against the draw in hand, which is why it
    /// carries the card and the feature and not only the shape: which curve the geometry
    /// takes (grow, collapse or page turn), whether content slides along a swipe's axis or
    /// unfolds out of the notch, and whether the island owes the arrival a beat. The extra
    /// update the write schedules is inert — nothing downstream of it draws differently.
    @State private var previousDraw: IslandDraw?
    /// Whether the island is holding its arrival beat (see ``IslandArrival``). One `Bool`,
    /// written twice per arrival and never at rest.
    @State private var isBeating = false
    /// The sleep that ends the current beat, held so it can be cancelled — by the next
    /// arrival, which restarts the beat, or by a real layout change, which takes the frame
    /// away from it.
    @State private var beatTask: Task<Void, Never>?

    /// The app's initialiser: the island follows the Reduce Motion setting as it changes.
    public init(
        presenter: IslandPresenter,
        geometry: NotchGeometry,
        motion: MotionSettings = .shared
    ) {
        self.presenter = presenter
        self.geometry = geometry
        self.pinnedChoreographer = nil
        self.motion = motion
    }

    /// Pins one choreography for the life of the view — tests and previews, which must not
    /// change behaviour with the setting on the machine running them.
    public init(presenter: IslandPresenter, geometry: NotchGeometry, choreographer: TransitionChoreographer) {
        self.presenter = presenter
        self.geometry = geometry
        self.pinnedChoreographer = choreographer
        self.motion = nil
    }

    public var body: some View {
        // Bound once: in the app this resolves the live Reduce Motion setting, and every
        // decision below has to be made against the same answer.
        let choreographer = self.choreographer
        let current = presenter.current
        let layout = IslandLayout.resolve(state: presenter.state, current: current, geometry: geometry)
        // The notch itself is the floor: the black shape may cover it, never sit inside it.
        let floor = CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        let draw = IslandDraw(layout: layout, presentationID: current?.id, featureID: current?.featureID)
        let presentationChanged = previousDraw?.presentationID != draw.presentationID
        let kind = TransitionChoreographer.kind(
            from: previousDraw?.layout,
            to: layout,
            presentationChanged: presentationChanged
        )
        let animation = choreographer.geometryAnimation(
            from: previousDraw?.layout,
            to: layout,
            presentationChanged: presentationChanged
        )
        // A swipe, and only a swipe, gives content an axis to travel along.
        let pageDirection = kind == .pageChange ? presenter.cycleDirection(arrivingAt: current?.id) : nil
        // Decided here, where the *previous* draw is still readable, and carried out by the
        // `onChange` below, which runs after this body with the same captured value.
        let beatChange = IslandArrival.beatChange(
            arrives: IslandArrival.shouldBeat(from: previousDraw, to: draw, isReduced: choreographer.isReduced),
            layoutChanged: previousDraw.map { $0.layout != layout } ?? false,
            isHeld: isBeating
        )
        let shapeSize = isBeating ? IslandArrival.beat(layout.size) : layout.size

        ZStack(alignment: .top) {
            NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
                .fill(Color.black)
                .islandFrame(size: shapeSize, flare: layout.topRadius, minimum: floor)
                .contentShape(Rectangle())
                .onTapGesture { presenter.toggleHoverPromotion() }
                // The island's own menu rides the black shape, under the content rather
                // than around it: a right-click opens only the innermost `.contextMenu`
                // it lands in, so wrapping the whole island here would shadow the menus
                // the features attach to their own views. Landing on the shape — the
                // notch cutout between the peek slots, the margins of an expanded panel —
                // gives the cards; landing on feature content gives that feature's menu,
                // which embeds `CardsMenuSection` to offer the same rows.
                .contextMenu { CardsMenuSection(presenter: presenter) }
                .overlay(alignment: .trailing) { stackDots(layout: layout, current: current) }

            content(layout: layout, current: current, pageDirection: pageDirection)
                .islandFrame(size: layout.size, minimum: floor, alignment: .top)
                .clipShape(NotchShape(topRadius: 0, bottomRadius: layout.bottomRadius))
                // Features whose expanded view reproduces the peek's geometry need the
                // notch's measurements, and only this layer knows them.
                .environment(\.notchSize, floor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: layout)
        .animation(animation, value: presenter.state)
        // One handler for both halves of a draw, so the order the two used to run in can
        // no longer decide whether the island beats.
        .onChange(of: draw, initial: true) { _, new in
            previousDraw = new
            apply(beatChange, choreographer: choreographer)
        }
    }

    private func apply(_ change: IslandArrival.BeatChange, choreographer: TransitionChoreographer) {
        switch change {
        case .start: startArrivalBeat(choreographer: choreographer)
        case .cancel: cancelArrivalBeat()
        case .none: break
        }
    }

    /// Pushes the island outward by a few points and pulls it back, so a card taking over
    /// an island that is not otherwise moving is still *announced* by the shape.
    ///
    /// Two state writes and one sleep — no timer, nothing repeating, nothing running once
    /// the island has settled. Re-entrant: a second arrival inside the hold cancels the
    /// first beat's sleep and starts its own, rather than being cut short by it.
    private func startArrivalBeat(choreographer: TransitionChoreographer) {
        beatTask?.cancel()
        withAnimation(choreographer.arrival) { isBeating = true }
        beatTask = Task { @MainActor in
            try? await Task.sleep(for: IslandArrival.hold)
            guard !Task.isCancelled else { return }
            withAnimation(choreographer.arrival) { isBeating = false }
            beatTask = nil
        }
    }

    /// Drops a beat the island no longer owns the frame for.
    ///
    /// Without animation on purpose: the beat's spring is deliberately loose (0.62), and
    /// letting it settle *through* a move the user asked for — an expand, a page turn —
    /// puts a wobble on that move. The few points it has travelled are absorbed by the
    /// geometry transaction that is starting in the same turn.
    private func cancelArrivalBeat() {
        beatTask?.cancel()
        beatTask = nil
        guard isBeating else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isBeating = false }
    }

    /// Content enters and leaves on its own curves, not on the geometry spring: the
    /// per-transition `.animation(_:)` overrides the transaction animation supplied by
    /// the `.animation(choreographer.geometry, value:)` modifiers on `body`, so the shape
    /// springs while the content springs slightly quicker.
    ///
    /// Both curves start in the same frame as the shape and overlap it — no delay on the
    /// way in, no early exit on the way out. Content that waits for the shape, or leaves
    /// before it, is what makes the island read as two objects instead of one.
    /// A page turn is the exception: both sides ride one curve — the same one in both
    /// directions, because a page turn is one gesture — and slide along the swipe's axis
    /// *inside the island's own clip*, so content passes under the island's edge instead
    /// of a panel arriving from outside it.
    private func contentTransition(pageDirection: IslandPresenter.CycleDirection?) -> AnyTransition {
        let isReduced = choreographer.isReduced
        if let pageDirection {
            return .asymmetric(
                insertion: .islandContent(.page(pageDirection, inserting: true, isReduced: isReduced))
                    .animation(choreographer.pageChange),
                removal: .islandContent(.page(pageDirection, inserting: false, isReduced: isReduced))
                    .animation(choreographer.pageChange)
            )
        }
        let motion = IslandContentMotion.unfold(isReduced: isReduced)
        return .asymmetric(
            insertion: .islandContent(motion).animation(choreographer.contentIn),
            removal: .islandContent(motion).animation(choreographer.contentOut)
        )
    }

    /// One dot per card, hugging the right edge inside the black body. Purely decorative:
    /// it sits in an overlay with hit testing off, so neither the content's layout nor the
    /// tap target on the shape changes when the stack grows.
    ///
    /// Expanded only. In peek the two 56 pt slots run all the way to the shape's edges, so
    /// the dots would land on top of whatever the front card is showing there — and the
    /// card the user is looking at is the one the dots are about anyway.
    ///
    /// While a transient alert borrows the island, *no* dot is lit: the alert is an
    /// interruption, not a page of the stack. Marking the card underneath it said the
    /// island was showing Music while the panel on screen was the Code completion.
    ///
    /// A card can opt out entirely (``Presentation/showsStackDots``): the Drop Zones
    /// panel is up only while a drag is in the air, and dots over it read as "swipe me"
    /// on a card there is no swiping away from.
    ///
    /// The marker is one bright dot drawn *over* a track of dim ones rather than one dot
    /// in the row being brightened: a single view can travel between positions and grow,
    /// which is how every page indicator in the system confirms a swipe. Crossfading two
    /// opacities made the dots blink, so the swipe had no feedback at all.
    @ViewBuilder
    private func stackDots(layout: IslandLayout, current: Presentation?) -> some View {
        let count = presenter.stack.count
        if count > 1, layout.mode == .expanded, current?.showsStackDots != false {
            // `stackIndex` is already `nil` while a transient alert borrows the island.
            let index = presenter.stackIndex
            let isReduced = choreographer.isReduced
            ZStack(alignment: .top) {
                VStack(spacing: StackDotMetrics.spacing) {
                    ForEach(0..<count, id: \.self) { _ in
                        Circle()
                            .fill(Color.white.opacity(StackDotMetrics.dimOpacity))
                            .frame(width: StackDotMetrics.size, height: StackDotMetrics.size)
                    }
                }
                if let index {
                    let diameter = StackDotMetrics.activeDiameter(isReduced: isReduced)
                    Circle()
                        .fill(Color.white)
                        .frame(width: diameter, height: diameter)
                        .offset(y: StackDotMetrics.activeOffset(index: index, isReduced: isReduced))
                }
            }
            // A fixed track width, so the dim dots do not shift by half a point when the
            // marker is withdrawn for a transient alert.
            .frame(width: StackDotMetrics.activeSize)
            // The shape's frame includes the flares, so the black body's right edge sits
            // `topRadius` inside it: the dots clear both.
            .padding(.trailing, Self.dotInset + layout.topRadius)
            .allowsHitTesting(false)
            .animation(choreographer.stackDot, value: index)
            // The group belongs to the panel: it arrives and leaves with it rather than
            // snapping in at full strength once the panel is already open.
            .transition(.opacity)
        }
    }

    private static let dotInset: CGFloat = 6

    @ViewBuilder
    private func content(
        layout: IslandLayout,
        current: Presentation?,
        pageDirection: IslandPresenter.CycleDirection?
    ) -> some View {
        let contentTransition = contentTransition(pageDirection: pageDirection)
        switch layout.mode {
        case .collapsed:
            Color.clear
        case .peek:
            if let current {
                PeekRow(
                    leading: current.leading,
                    trailing: current.trailing,
                    notch: CGSize(width: geometry.notchWidth, height: geometry.notchHeight),
                    slotWidth: current.peekSlotWidth
                )
                    .id("peek-\(current.id)")
                    .transition(contentTransition)
            }
        case .expanded:
            if let current, let expanded = current.expanded {
                expanded
                    .padding(.top, geometry.notchHeight)
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
                    .id("expanded-\(current.id)")
                    .transition(contentTransition)
            }
        }
    }
}
