import Foundation

/// Decides whether a new snapshot is worth sending and strips artwork bytes when the
/// receiver already has them. Used by the helper; pure so it is testable.
public struct SnapshotDedup: Sendable {
    private let driftTolerance: TimeInterval
    private var lastSent: NowPlayingSnapshot?
    /// The artwork id whose *bytes* the receiver is believed to hold.
    private var lastSentArtworkID: String?
    /// The artwork id of the last snapshot the receiver saw, bytes or not. The receiver keeps its
    /// artwork only while the incoming id matches the previous snapshot's, so this is what decides
    /// whether the belief above is still true.
    private var lastSeenArtworkID: String?

    public init(driftTolerance: TimeInterval = 1.5) {
        self.driftTolerance = driftTolerance
    }

    public mutating func reset() {
        lastSent = nil
        lastSentArtworkID = nil
        lastSeenArtworkID = nil
    }

    public mutating func prepare(_ new: NowPlayingSnapshot, now: Date) -> NowPlayingSnapshot? {
        // The receiver throws its artwork away the moment a snapshot arrives under a different id
        // (`MusicViewModel.mergeArtwork`), so an id that changed since the last snapshot means the
        // bytes sent for it are gone. MediaRemote replays the outgoing track for a moment after a
        // skip, which puts exactly such a snapshot between two of the new track's: without this,
        // the bytes would stay recorded as delivered, be stripped from every later snapshot, and
        // the cover would be missing until the next track change.
        if new.artworkID != lastSeenArtworkID { lastSentArtworkID = nil }
        defer { lastSeenArtworkID = new.artworkID }
        // MediaRemote often delivers the image bytes in a later info update than the metadata
        // that names them. Such an update differs from the last one in no field `isEquivalent`
        // looks at, so it has to be forced through or the artwork never reaches the receiver.
        let carriesUnsentArtwork = new.artworkData != nil && new.artworkID != lastSentArtworkID
        if !carriesUnsentArtwork, let last = lastSent, isEquivalent(last, new, now: now) {
            return nil
        }
        var out = new
        if let id = new.artworkID, id == lastSentArtworkID {
            out.artworkData = nil
        } else if new.artworkData != nil {
            lastSentArtworkID = new.artworkID
        }
        // `isEquivalent` never reads artwork bytes, so keep the comparison baseline without them
        // rather than holding an album cover alive for the lifetime of the track.
        var kept = new
        kept.artworkData = nil
        lastSent = kept
        return out
    }

    /// Bytes the dedup is holding on to. Always 0: `isEquivalent` never reads artwork data, so
    /// there is no reason to keep an album cover alive in `lastSent`.
    var retainedArtworkByteCount: Int { lastSent?.artworkData?.count ?? 0 }

    private func isEquivalent(_ a: NowPlayingSnapshot, _ b: NowPlayingSnapshot, now: Date) -> Bool {
        guard a.title == b.title, a.artist == b.artist, a.album == b.album,
              a.artworkID == b.artworkID, a.duration == b.duration,
              a.playbackRate == b.playbackRate, a.sourceBundleID == b.sourceBundleID else { return false }
        let predicted = PlaybackProgressTracker.elapsed(for: a, at: now)
        let actual = PlaybackProgressTracker.elapsed(for: b, at: now)
        switch (predicted, actual) {
        case (nil, nil): return true
        case let (p?, q?): return abs(p - q) <= driftTolerance
        default: return false
        }
    }
}
