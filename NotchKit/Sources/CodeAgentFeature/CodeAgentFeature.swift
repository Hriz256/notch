import Foundation
import IslandCore

/// The "Code" island feature. Wiring is filled in by later tasks.
@MainActor
public final class CodeAgentFeature: IslandFeature {
    public let id = FeatureID("code")

    public init() {}

    public func activate(presenter: any IslandPresenting) {}

    public func deactivate() {}
}
