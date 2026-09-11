import Foundation

public enum PlaybackProgressTracker {
    /// Projects `snapshot.elapsed` to `now` using the playback rate, clamped to [0, duration].
    public static func elapsed(for snapshot: NowPlayingSnapshot, at now: Date) -> TimeInterval? {
        guard let base = snapshot.elapsed else { return nil }
        let delta = now.timeIntervalSince(snapshot.timestamp)
        var value = base + delta * snapshot.playbackRate
        if let duration = snapshot.duration { value = min(value, duration) }
        return max(0, value)
    }
}
