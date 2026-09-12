import DropZonesShared
import Foundation
import Observation

/// User preferences for the Drop Zones feature, backed by `UserDefaults`.
///
/// Same shape as `CodeSettings`: the values are mirrored into an observable
/// in-memory cache so SwiftUI menus and views re-render when they change, and
/// every setter writes through to `UserDefaults` immediately — there is no save
/// step and nothing to lose on a crash. The cache is a set of private stored
/// properties with public computed ones over them, because `@Observable` tracks
/// stored properties and the write-through belongs in the setter.
///
/// Keys (spec §2): `dropzones.airdrop`, `dropzones.stash`, `dropzones.secondZone`,
/// `dropzones.stashDropAction`.
@MainActor
@Observable
public final class DropZonesSettings {

    // MARK: - Keys

    public static let airdropKey = "dropzones.airdrop"
    public static let stashKey = "dropzones.stash"
    public static let secondZoneKey = "dropzones.secondZone"
    public static let stashDropActionKey = "dropzones.stashDropAction"

    // MARK: - Storage

    @ObservationIgnored private let defaults: UserDefaults

    private var airdropValue: Bool
    private var stashValue: Bool
    private var secondZoneValue: Bool
    private var stashDropActionValue: StashDropAction

    /// - Parameter defaults: injected so tests get a throw-away suite. A key that
    ///   has never been written keeps the spec's default; an unreadable drop
    ///   action (a hand-edited plist, a value from a future version) falls back to
    ///   `.add` rather than refusing to start.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        airdropValue = defaults.object(forKey: Self.airdropKey) as? Bool ?? true
        stashValue = defaults.object(forKey: Self.stashKey) as? Bool ?? true
        secondZoneValue = defaults.object(forKey: Self.secondZoneKey) as? Bool ?? false
        stashDropActionValue = defaults.string(forKey: Self.stashDropActionKey)
            .flatMap(StashDropAction.init(rawValue:)) ?? .add
    }

    // MARK: - Settings

    /// Whether the AirDrop card is offered (default on).
    public var airdrop: Bool {
        get { airdropValue }
        set {
            airdropValue = newValue
            defaults.set(newValue, forKey: Self.airdropKey)
        }
    }

    /// Whether the File Stash card is offered (default on). With it off there is
    /// no drag-out either — everything about the stash hangs off this card.
    public var stash: Bool {
        get { stashValue }
        set {
            stashValue = newValue
            defaults.set(newValue, forKey: Self.stashKey)
        }
    }

    /// Whether the *other* stash action gets a card of its own (default off).
    public var secondZone: Bool {
        get { secondZoneValue }
        set {
            secondZoneValue = newValue
            defaults.set(newValue, forKey: Self.secondZoneKey)
        }
    }

    /// What a drop on the main stash card does (default `.add`); the third card,
    /// when it is shown, does the other one.
    ///
    /// Seam's own default is Replace, but a stash the user drops a second file into
    /// and finds emptied of the first is the one behaviour nobody expects — files
    /// accumulate. "Replace" stays a menu row away, and a card of its own.
    public var stashDropAction: StashDropAction {
        get { stashDropActionValue }
        set {
            stashDropActionValue = newValue
            defaults.set(newValue.rawValue, forKey: Self.stashDropActionKey)
        }
    }
}
