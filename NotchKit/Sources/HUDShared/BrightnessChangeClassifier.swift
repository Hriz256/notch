import Foundation

/// Tells a brightness change the user made from one the ambient light sensor made.
///
/// macOS shows its own brightness HUD only for the keys; the automatic adjustment that
/// follows the room's light is silent. DisplayServices reports both through the same
/// notification with nothing but the new value, so the two are told apart by the shape
/// of the signal, measured on a MacBook Pro on 2026-09-14:
///
/// - **Keys**: one notification, a jump of 1/16 of the scale (1/64 with Option+Shift),
///   landing exactly on that grid.
/// - **Ambient**: a ramp of ~0.0001 steps every 8 ms for 3–9 s, ending anywhere.
///   The fastest ramp seen moved 0.031/s.
///
/// Two rules, either of which makes a change manual: a single step of at least most of
/// a fine key step, or — for hardware that smooths key changes into a ramp — movement of
/// at least half a key step within ``rampWindow``. Ambient ramps clear neither by a wide
/// margin (a single ambient step is a hundredth of the first threshold, and 300 ms of
/// the fastest ramp a third of the second).
///
/// Pure: the caller owns the clock and feeds `(level, time)` in arrival order.
public struct BrightnessChangeClassifier: Equatable, Sendable {
    /// The brightness keys move the level by this much.
    public static let keyStep = 1.0 / 16.0
    /// Option+Shift with a brightness key moves it by this much.
    public static let fineKeyStep = 1.0 / 64.0
    /// A single notification that moves the level by at least this much is a key press.
    public static let instantThreshold = fineKeyStep * 0.75
    /// Movement of at least this much within ``rampWindow`` is a smoothed key press.
    public static let rampThreshold = keyStep / 2
    public static let rampWindow: Duration = .milliseconds(300)

    public enum Verdict: Equatable, Sendable {
        /// The user pressed a key (or dragged a slider fast enough to look like one).
        case manual
        /// The sensor, or anything else that creeps: not worth a HUD.
        case ambient
    }

    private struct Sample: Equatable, Sendable {
        var level: Double
        var time: Date
    }

    /// Recent levels, oldest first, all within ``rampWindow`` of the newest.
    private var samples: [Sample] = []

    public init() {}

    /// Records a level without judging it: the reading at registration.
    public mutating func record(level: Double, at time: Date) {
        samples = [Sample(level: level, time: time)]
    }

    /// Judges one change. A manual verdict resets the window, so the ambient creep that
    /// follows a key press is not carried along by the key's jump for the next 300 ms.
    public mutating func classify(level: Double, at time: Date) -> Verdict {
        defer { samples.append(Sample(level: level, time: time)) }
        guard let last = samples.last else { return .ambient }
        let cutoff = time.addingTimeInterval(-Self.rampWindow.seconds)
        samples.removeAll { $0.time < cutoff }

        let instant = abs(level - last.level) >= Self.instantThreshold
        let ramped = samples.contains { abs(level - $0.level) >= Self.rampThreshold }
        if instant || ramped {
            samples.removeAll()
            return .manual
        }
        return .ambient
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
