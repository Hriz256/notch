import Foundation

public enum TimeFormatting {
    /// Anything at or beyond this magnitude is nonsense for a track position (over 31 years).
    private static let magnitudeLimit: TimeInterval = 1e9

    /// "m:ss", minutes not padded, never negative. NaN, infinities and absurd magnitudes —
    /// which live streams do report — format as "0:00" rather than trapping in `Int(_:)`.
    public static func mmss(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, abs(seconds) < magnitudeLimit else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
