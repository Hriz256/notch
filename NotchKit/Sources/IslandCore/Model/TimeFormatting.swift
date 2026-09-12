import Foundation

/// Clock formatting shared by the island's features.
///
/// A deliberate copy of `NowPlayingShared.TimeFormatting`: it is a dozen lines, and the
/// alternative was for every feature that shows a running clock to depend on the Now Playing
/// module for it. Features that already import `NowPlayingShared` keep using that one — the
/// two must stay in step, which the tests on both sides enforce.
public enum TimeFormatting {
    /// Anything at or beyond this magnitude is nonsense for a clock (over 31 years).
    private static let magnitudeLimit: TimeInterval = 1e9

    /// "m:ss", minutes not padded, never negative. NaN, infinities and absurd magnitudes
    /// format as "0:00" rather than trapping in `Int(_:)`.
    public static func mmss(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, abs(seconds) < magnitudeLimit else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
