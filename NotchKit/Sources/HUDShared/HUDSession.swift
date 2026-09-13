import Foundation

/// The one-HUD-at-a-time state machine (spec §3.1). Pure: the caller owns the clock and
/// calls ``expire()`` when the hold runs out.
///
/// Two pieces of memory: what is on screen (`current`) and the last value seen per kind
/// (the baselines). A reading equal to the baseline of its kind is not a change — that is
/// what keeps the first reading after registration, and a duplicate notification, off the
/// island.
public struct HUDSession: Equatable, Sendable {
    /// How long a HUD stays after the last change (spec §2 "Timing").
    public static let holdDuration: Duration = .milliseconds(1500)

    public enum Effect: Equatable, Sendable {
        /// Nothing was up: present a fresh HUD.
        case present(HUDReading)
        /// The same kind is up: re-present under the same id.
        case update(HUDReading)
        /// The other kind is up: dismiss it, present this one afresh.
        case replace(HUDReading)
        /// Not a change, or nothing to show.
        case none
    }

    /// What is on screen, or `nil` between HUDs.
    public private(set) var current: HUDReading?
    private var baselines: [HUDKind: HUDReading] = [:]

    public init() {}

    /// Records a value without presenting it — the reading at registration, or the new
    /// device's level after an output-device switch.
    public mutating func baseline(_ reading: HUDReading) {
        baselines[reading.kind] = reading
    }

    public mutating func receive(_ reading: HUDReading) -> Effect {
        defer { baselines[reading.kind] = reading }
        if let current {
            if current == reading { return .none }
            self.current = reading
            return current.kind == reading.kind ? .update(reading) : .replace(reading)
        }
        if baselines[reading.kind] == reading { return .none }
        current = reading
        return .present(reading)
    }

    /// The hold ran out. Returns whether anything was up.
    public mutating func expire() -> Bool {
        defer { current = nil }
        return current != nil
    }
}
