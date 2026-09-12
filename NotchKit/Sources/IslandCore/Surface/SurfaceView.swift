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
        let animation = choreographer.geometryAnimation(from: previousLayout, to: layout)

        ZStack(alignment: .top) {
            NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
                .fill(Color.black)
                .islandFrame(size: layout.size, flare: layout.topRadius, minimum: floor)
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
                .overlay(alignment: .trailing) { stackDots(layout: layout) }

            content(layout: layout, current: current)
                .islandFrame(size: layout.size, minimum: floor, alignment: .top)
                .clipShape(NotchShape(topRadius: 0, bottomRadius: layout.bottomRadius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: layout)
        .animation(animation, value: presenter.state)
        .onChange(of: layout, initial: true) { _, new in previousLayout = new }
    }

    /// Content enters and leaves on its own curves, not on the geometry spring: the
    /// per-transition `.animation(_:)` overrides the transaction animation supplied by
    /// the `.animation(choreographer.geometry, value:)` modifiers on `body`, so the
    /// shape still springs while content eases in (delayed) and eases out (immediately).
    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .islandContent(usesBlur: choreographer.usesBlur)
                .animation(choreographer.contentIn),
            removal: .islandContent(usesBlur: choreographer.usesBlur)
                .animation(choreographer.contentOut)
        )
    }

    /// One dot per card, hugging the right edge inside the black body. Purely decorative:
    /// it sits in an overlay with hit testing off, so neither the content's layout nor the
    /// tap target on the shape changes when the stack grows.
    ///
    /// Expanded only. In peek the two 56 pt slots run all the way to the shape's edges, so
    /// the dots would land on top of whatever the front card is showing there — and the
    /// card the user is looking at is the one the dots are about anyway.
    @ViewBuilder
    private func stackDots(layout: IslandLayout) -> some View {
        let count = presenter.stack.count
        if count > 1, layout.mode == .expanded {
            let index = presenter.stackIndex
            VStack(spacing: Self.dotSpacing) {
                ForEach(0..<count, id: \.self) { position in
                    Circle()
                        .fill(Color.white.opacity(position == index ? 1 : 0.35))
                        .frame(width: Self.dotSize, height: Self.dotSize)
                }
            }
            // The shape's frame includes the flares, so the black body's right edge sits
            // `topRadius` inside it: the dots clear both.
            .padding(.trailing, Self.dotInset + layout.topRadius)
            .allowsHitTesting(false)
            .animation(choreographer.contentIn, value: index)
        }
    }

    private static let dotSize: CGFloat = 3
    private static let dotSpacing: CGFloat = 5
    private static let dotInset: CGFloat = 6

    @ViewBuilder
    private func content(layout: IslandLayout, current: Presentation?) -> some View {
        switch layout.mode {
        case .collapsed:
            Color.clear
        case .peek:
            if let current {
                PeekRow(
                    leading: current.leading,
                    trailing: current.trailing,
                    notch: CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
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

/// The peek island's content: one ``IslandLayout/peekSlotWidth`` slot hugging each edge of
/// the island, with the notch between them.
///
/// The row **fills** the width it is proposed instead of measuring a fixed
/// `notch + 2 * slot`. That distinction only shows up while the island's width is in
/// flight: `IslandFrame` interpolates the width frame by frame, and a fixed-width row stays
/// centred on the notch while the island's edges slide past it — so for the whole length of
/// every peek ↔ expanded transition each glyph walks toward the notch. At the Code card's
/// 380 pt expanded width the leading glyph ends up 69 pt from the island's left edge
/// instead of 28, close enough to the notch to read as sitting under it.
///
/// Filling glues each slot to the edge it belongs to at every intermediate width. The gap
/// is a `Spacer` with the notch as its *minimum* rather than its exact width, so the row
/// still measures `notch + 2 * slot` when it is proposed less than that (collapsing, where
/// the island clips the row anyway) and the two glyphs can never meet behind the notch.
struct PeekRow: View {
    let leading: AnyView
    let trailing: AnyView
    let notch: CGSize

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: IslandLayout.peekSlotWidth, height: notch.height)
            Spacer(minLength: notch.width)
            trailing
                .frame(width: IslandLayout.peekSlotWidth, height: notch.height)
        }
        .frame(maxWidth: .infinity)
    }
}
