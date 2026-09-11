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

    @ViewBuilder
    private func content(layout: IslandLayout, current: Presentation?) -> some View {
        switch layout.mode {
        case .collapsed:
            Color.clear
        case .peek:
            if let current {
                HStack(spacing: 0) {
                    current.leading
                        .frame(width: IslandLayout.peekSlotWidth, height: geometry.notchHeight)
                    Spacer().frame(width: geometry.notchWidth)
                    current.trailing
                        .frame(width: IslandLayout.peekSlotWidth, height: geometry.notchHeight)
                }
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
