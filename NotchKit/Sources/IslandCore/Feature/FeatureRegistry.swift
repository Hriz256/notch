import Foundation
import Observation

/// Holds all features, persists their on/off state and activates/deactivates them.
@MainActor
@Observable
public final class FeatureRegistry {
    public private(set) var features: [any IslandFeature] = []
    @ObservationIgnored private let presenter: any IslandPresenting
    @ObservationIgnored private let defaults: UserDefaults
    private var enabled: [FeatureID: Bool] = [:]

    public init(presenter: any IslandPresenting, defaults: UserDefaults = .standard) {
        self.presenter = presenter
        self.defaults = defaults
    }

    public static func defaultsKey(_ id: FeatureID) -> String { "feature.\(id.rawValue).enabled" }

    public func register(_ feature: any IslandFeature, enabledByDefault: Bool = true) {
        features.append(feature)
        let key = Self.defaultsKey(feature.id)
        let isOn = defaults.object(forKey: key) == nil ? enabledByDefault : defaults.bool(forKey: key)
        enabled[feature.id] = isOn
        if isOn { feature.activate(presenter: presenter) }
    }

    public func isEnabled(_ id: FeatureID) -> Bool { enabled[id] ?? false }

    public func setEnabled(_ id: FeatureID, _ value: Bool) {
        guard let feature = features.first(where: { $0.id == id }), enabled[id] != value else { return }
        enabled[id] = value
        defaults.set(value, forKey: Self.defaultsKey(id))
        if value { feature.activate(presenter: presenter) } else { feature.deactivate() }
    }

    public func deactivateAll() {
        for feature in features where isEnabled(feature.id) { feature.deactivate() }
    }
}
