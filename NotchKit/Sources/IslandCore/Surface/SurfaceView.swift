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
    private let choreographer: TransitionChoreographer

    /// Last layout handed to `.animation(_:value:)`. Written only from `onChange`, which runs
    /// after `body`, so the value read while building `body` is genuinely the previous one.
    /// It feeds nothing but the choice of curve, so the extra update it schedules is inert.
    @State private var previousLayout: IslandLayout?
    /// The card `body` last drew, tracked the same way and for the same reason: a page
    /// turn is told from a grow by *identity*, not by size.
    @State private var previousPresentationID: PresentationID?
    /// Whether the island is holding its arrival beat (see ``IslandArrival``). One
    /// `Bool`, set twice per arrival and never at rest.
    @State private var isBeating = false

    public init(presenter: IslandPresenter, geometry: NotchGeometry, choreographer: TransitionChoreographer) {
        self.presenter = presenter
        self.geometry = geometry
        self.choreographer = choreographer
    }

    public var body: some View {
        let current = presenter.current
        let layout = IslandLayout.resolve(state: presenter.state, current: current, geometry: geometry)
        // The notch itself is the floor: the black shape may cover it, never sit inside it.
        let floor = CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        let presentationChanged = previousPresentationID != current?.id
        let kind = TransitionChoreographer.kind(
            from: previousLayout,
            to: layout,
            presentationChanged: presentationChanged
        )
        let animation = choreographer.geometryAnimation(
            from: previousLayout,
            to: layout,
            presentationChanged: presentationChanged
        )
        // A swipe, and only a swipe, gives content an axis to travel along.
        let pageDirection = kind == .pageChange ? presenter.cycleDirection(arrivingAt: current?.id) : nil
        // Decided here, where the *previous* layout is still readable, and consumed by the
        // `onChange` below, which runs after this body with the same captured value.
        let announcesArrival = IslandArrival.shouldBeat(
            from: previousLayout,
            to: layout,
            presentationChanged: presentationChanged,
            isReduced: choreographer.isReduced
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
        .onChange(of: layout, initial: true) { _, new in previousLayout = new }
        .onChange(of: current?.id, initial: true) { _, new in
            previousPresentationID = new
            if announcesArrival { playArrivalBeat() }
        }
    }

    /// Swells the island by a few points and lets it settle, so a card taking over an
    /// island that is not otherwise moving is still *announced* by the shape.
    ///
    /// Two state writes and one sleep — no timer, nothing repeating, nothing running once
    /// the island has settled.
    private func playArrivalBeat() {
        withAnimation(choreographer.arrival) { isBeating = true }
        Task { @MainActor in
            try? await Task.sleep(for: IslandArrival.hold)
            withAnimation(choreographer.arrival) { isBeating = false }
        }
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
            let index = presenter.isShowingTransientAlert ? nil : presenter.stackIndex
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
