import Testing
import Foundation
@testable import NowPlayingShared

/// Artwork bookkeeping in `SnapshotDedup`: MediaRemote routinely delivers the image bytes in a
/// later info update than the metadata that names them, so the id and the bytes arrive apart.
struct SnapshotDedupArtworkTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func snap(title: String = "Song", artworkID: String?, artwork: Data?) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: title, artist: "Artist", album: "Album",
                           artworkData: artwork, artworkID: artworkID,
                           duration: 200, elapsed: 10, playbackRate: 1,
                           sourceBundleID: "com.spotify.client", timestamp: t0)
    }

    @Test func lateArrivingArtworkIsSent() {
        var d = SnapshotDedup()
        // #1: metadata only — the helper has not loaded the image for "a" yet.
        let first = d.prepare(snap(artworkID: "a", artwork: nil), now: t0)
        #expect(first != nil)
        #expect(first?.artworkData == nil)
        // #2: identical in every other field, but now it carries the bytes for "a".
        let second = d.prepare(snap(artworkID: "a", artwork: Data([7, 7])), now: t0)
        #expect(second?.artworkData == Data([7, 7]))
    }

    @Test func artworkIDAdvancesOnlyWhenBytesAreCarried() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(artworkID: "a", artwork: Data([1])), now: t0)
        // The id moves to "b" but no bytes come with it — the receiver still has only "a".
        let idOnly = d.prepare(snap(title: "Other", artworkID: "b", artwork: nil), now: t0)
        #expect(idOnly?.artworkID == "b")
        #expect(idOnly?.artworkData == nil)
        // The bytes for "b" land later and must go out.
        let withBytes = d.prepare(snap(title: "Other", artworkID: "b", artwork: Data([2])), now: t0)
        #expect(withBytes?.artworkData == Data([2]))
    }

    @Test func alreadySentArtworkIsStillStripped() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(artworkID: "a", artwork: Data([1])), now: t0)
        let out = d.prepare(snap(title: "Other", artworkID: "a", artwork: Data([1])), now: t0)
        #expect(out?.title == "Other")
        #expect(out?.artworkData == nil)
    }

    @Test func dedupDoesNotRetainArtworkBytes() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(artworkID: "a", artwork: Data([1, 2, 3])), now: t0)
        #expect(d.retainedArtworkByteCount == 0)
    }
}
