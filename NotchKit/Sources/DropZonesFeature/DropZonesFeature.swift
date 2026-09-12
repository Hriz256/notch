import DropZonesShared
import Foundation
import IslandCore

/// The "Drop Zones" island feature: drag detection, the drop catcher, the stash
/// and the island views.
///
/// A placeholder for now — it owns nothing but its id, so the registry can list
/// and toggle the feature while the machinery behind it is built. `activate` and
/// `deactivate` stay a no-op pair rather than being left unimplemented, because
/// the registry calls `deactivate` on every master-switch change including for a
/// feature that was never activated.
@MainActor
public final class DropZonesFeature: IslandFeature {
    public static let featureID = FeatureID("dropzones")

    public let id = DropZonesFeature.featureID

    public init() {}

    // MARK: - Lifecycle

    public func activate(presenter: any IslandPresenting) {}

    public func deactivate() {}
}
