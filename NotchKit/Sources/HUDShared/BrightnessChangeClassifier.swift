import Foundation

/// Tells a brightness change the user made from one the ambient light sensor made.
///
/// macOS shows its own brightness HUD only for the keys; the automatic adjustment that
/// follows the room's light is silent. DisplayServices reports both through the same
/// notification with nothing but the new value, so the two are told apart by the shape
/// of the signal, measured on a MacBook Pro on 2026-09-14:
///
/// - **Keys**: one notification, a jump of 1/16 of the scale (1/64 with Option+Shift),
///   landing exactly on that grid — a press after the sensor left the level off the grid
///   snaps it back onto it.
/// - **Ambient**: a ramp of small steps every 8 ms. A gentle change creeps at ~0.0001 a
///   step; covering the sensor outright moved 0.42 → 0.98 in 1.9 s, with steps of up to
///   0.004 — fast, but still a ramp of small steps ending anywhere.
///
/// So a change is manual when a *single* notification moves the level by at least most
/// of a fine key step and lands on the 1/64 grid. Speed over a window is deliberately not
/// a criterion: a strong ambient change is as fast as any smoothed key press would be.
/// Ambient steps stay a third of the size threshold even at their fastest, and the grid
/// test catches what would slip through.
///
/// Pure: the caller feeds levels in arrival order.
public struct BrightnessChangeClassifier: Equatable, Sendable {
    /// The brightness keys move the level by this much.
    public static let keyStep = 1.0 / 16.0
    /// Option+Shift with a brightness key moves it by this much; also the grid keys land on.
    public static let fineKeyStep = 1.0 / 64.0
    /// A single notification has to move the level by at least this much to be a key press.
    public static let stepThreshold = fineKeyStep * 0.75
    /// How far off the 1/64 grid a level may be and still count as on it. The keys land on
    /// the grid to float precision, so this only has to absorb rounding; anything wider
    /// starts admitting ambient levels (the grid points are 0.0156 apart).
    public static let gridTolerance = 0.0005

    public enum Verdict: Equatable, Sendable {
        /// The user pressed a key.
        case manual
        /// The sensor, a slider drag, or anything else that creeps: not worth a HUD.
        case ambient
    }

    private var last: Double?

    public init() {}

    /// Records a level without judging it: the reading at registration.
    public mutating func record(level: Double) {
        last = level
    }

    /// Judges one change against the level before it.
    public mutating func classify(level: Double) -> Verdict {
        defer { last = level }
        guard let last else { return .ambient }
        let bigEnough = abs(level - last) >= Self.stepThreshold
        return bigEnough && Self.isOnGrid(level) ? .manual : .ambient
    }

    /// Whether `level` sits on the 1/64 grid, within ``gridTolerance``.
    public static func isOnGrid(_ level: Double) -> Bool {
        let steps = level / fineKeyStep
        return abs(steps - steps.rounded()) * fineKeyStep <= gridTolerance
    }
}
