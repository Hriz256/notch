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

    public init(presenter: IslandPresenter, geometry: NotchGeometry, choreographer: TransitionChoreographer) {
        self.presenter = presenter
        self.geometry = geometry
        self.choreographer = choreographer
    }

    public var body: some View {
        let current = presenter.current
        let layout = IslandLayout.resolve(state: presenter.state, current: current, geometry: geometry)

        ZStack(alignment: .top) {
            NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius)
                .fill(Color.black)
                .frame(width: layout.size.width + 2 * layout.topRadius, height: layout.size.height)
                .contentShape(Rectangle())
                .onTapGesture { presenter.toggleHoverPromotion() }

            content(layout: layout, current: current)
                .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
                .clipShape(NotchShape(topRadius: 0, bottomRadius: layout.bottomRadius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(choreographer.geometry, value: layout)
        .animation(choreographer.geometry, value: presenter.state)
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
                .transition(.islandContent(usesBlur: choreographer.usesBlur))
            }
        case .expanded:
            if let current, let expanded = current.expanded {
                expanded
                    .padding(.top, geometry.notchHeight)
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
                    .id("expanded-\(current.id)")
                    .transition(.islandContent(usesBlur: choreographer.usesBlur))
            }
        }
    }
}
