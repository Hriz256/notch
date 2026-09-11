import Testing
import Foundation
@testable import NowPlayingShared

struct SnapshotDedupTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let art = Data([1, 2, 3])

    func snap(title: String = "Song", elapsed: TimeInterval = 10, rate: Double = 1, artworkID: String? = "a1", artwork: Data? = nil, at: Date? = nil) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: title, artist: "Artist", album: "Album",
                           artworkData: artwork ?? art, artworkID: artworkID,
                           duration: 200, elapsed: elapsed, playbackRate: rate,
                           sourceBundleID: "com.spotify.client", timestamp: at ?? t0)
    }

    @Test func firstSnapshotIsSentWithArtwork() {
        var d = SnapshotDedup()
        let out = d.prepare(snap(), now: t0)
        #expect(out?.artworkData == art)
    }

    @Test func identicalSnapshotIsSkipped() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(), now: t0)
        #expect(d.prepare(snap(), now: t0) == nil)
    }

    @Test func expectedElapsedDriftIsSkipped() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(elapsed: 10), now: t0)
        // 5 s later, elapsed 15 is exactly what we predicted -> skip
        #expect(d.prepare(snap(elapsed: 15, at: t0.addingTimeInterval(5)), now: t0.addingTimeInterval(5)) == nil)
    }

    @Test func seekBeyondToleranceIsSent() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(elapsed: 10), now: t0)
        let out = d.prepare(snap(elapsed: 60, at: t0.addingTimeInterval(5)), now: t0.addingTimeInterval(5))
        #expect(out != nil)
    }

    @Test func sameArtworkIDStripsArtworkData() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(), now: t0)
        let out = d.prepare(snap(title: "Other"), now: t0)
        #expect(out?.title == "Other")
        #expect(out?.artworkData == nil)
        #expect(out?.artworkID == "a1")
    }

    @Test func newArtworkIDSendsArtwork() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(), now: t0)
        let out = d.prepare(snap(title: "Other", artworkID: "a2", artwork: Data([9])), now: t0)
        #expect(out?.artworkData == Data([9]))
    }

    @Test func pauseIsSent() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(rate: 1), now: t0)
        #expect(d.prepare(snap(rate: 0), now: t0) != nil)
    }

    @Test func resetForgetsArtwork() {
        var d = SnapshotDedup()
        _ = d.prepare(snap(), now: t0)
        d.reset()
        #expect(d.prepare(snap(), now: t0)?.artworkData == art)
    }
}
