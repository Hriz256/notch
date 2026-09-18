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

    /// MediaRemote replays the outgoing track for a moment after a skip. That replay lands
    /// between two snapshots of the new track, and the receiver drops its artwork the instant an
    /// id other than the one it holds arrives — so the bytes it was sent are gone and have to be
    /// sent again, even though this dedup had already recorded them as delivered.
    @Test func artworkIsResentAfterAnInterveningIDDropsItOnTheReceiver() {
        var d = SnapshotDedup()
        let sent = d.prepare(snap(title: "New", artworkID: "b", artwork: Data([2])), now: t0)
        #expect(sent?.artworkData == Data([2]))
        // The skip burst: the outgoing track comes back briefly, without bytes of its own.
        let echo = d.prepare(snap(title: "Old", artworkID: "a", artwork: nil), now: t0)
        #expect(echo?.artworkID == "a")
        // The receiver cleared "b" on the echo, so the new track's bytes must go out once more.
        let again = d.prepare(snap(title: "New", artworkID: "b", artwork: Data([2])), now: t0)
        #expect(again?.artworkData == Data([2]))
    }

    @Test func dedupDoesNotRetainArtworkBytes() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(artworkID: "a", artwork: Data([1, 2, 3])), now: t0)
        #expect(d.retainedArtworkByteCount == 0)
    }
}
