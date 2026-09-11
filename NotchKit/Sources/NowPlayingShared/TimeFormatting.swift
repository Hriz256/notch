import Foundation

public enum TimeFormatting {
    /// "m:ss", minutes not padded, never negative.
    public static func mmss(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
