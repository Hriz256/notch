import IslandCore
import SwiftUI

extension DropZonesFeature {
    /// The real views, handed to `DropZonesViewModel` at construction.
    ///
    /// The view model takes its views as a value so that every one of its tests can run
    /// without SwiftUI; this is the one place that value is built for the running app.
    static let viewFactory = DropZonesViewFactory(
        stashLeading: { AnyView(StashLeadingView(model: $0)) },
        stashTrailing: { AnyView(StashTrailingView(model: $0)) },
        stashExpanded: { AnyView(StashExpandedView(model: $0)) }
    )
}
