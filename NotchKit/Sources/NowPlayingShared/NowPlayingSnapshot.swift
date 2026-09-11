import Foundation

/// Everything the UI needs about the current track. `elapsed` is valid at `timestamp`;
/// use `PlaybackProgressTracker` to project it forward.
public struct NowPlayingSnapshot: Codable, Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// PNG/JPEG bytes. nil when unchanged since the last sent snapshot (compare `artworkID`).
    public var artworkData: Data?
    public var artworkID: String?
    public var duration: TimeInterval?
    public var elapsed: TimeInterval?
    /// 0 = paused, 1 = playing.
    public var playbackRate: Double
    public var sourceBundleID: String?
    public var timestamp: Date

    public init(title: String?, artist: String?, album: String?, artworkData: Data?, artworkID: String?,
                duration: TimeInterval?, elapsed: TimeInterval?, playbackRate: Double,
                sourceBundleID: String?, timestamp: Date) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.artworkID = artworkID
        self.duration = duration
        self.elapsed = elapsed
        self.playbackRate = playbackRate
        self.sourceBundleID = sourceBundleID
        self.timestamp = timestamp
    }

    public var isPlaying: Bool { playbackRate > 0 }
    public var hasTrack: Bool { !(title ?? "").isEmpty }

    /// Drops non-finite numbers, which MediaRemote reports for live streams. JSON cannot carry
    /// them, and downstream arithmetic on them is meaningless: `duration`/`elapsed` become nil,
    /// a non-finite `playbackRate` becomes 0 (paused).
    public func sanitized() -> NowPlayingSnapshot {
        var out = self
        if let duration, !duration.isFinite { out.duration = nil }
        if let elapsed, !elapsed.isFinite { out.elapsed = nil }
        if !playbackRate.isFinite { out.playbackRate = 0 }
        return out
    }

    /// Encodes `sanitized()`, so a non-finite value can never fail the encode.
    public func encoded() throws -> Data { try JSONEncoder().encode(sanitized()) }
    public static func decode(_ data: Data) throws -> NowPlayingSnapshot { try JSONDecoder().decode(NowPlayingSnapshot.self, from: data) }
}
