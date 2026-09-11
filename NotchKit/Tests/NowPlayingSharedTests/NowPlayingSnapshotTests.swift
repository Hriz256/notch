import Testing
import Foundation
@testable import NowPlayingShared

struct NowPlayingSnapshotTests {
    let t0 = Date(timeIntervalSince1970: 3_000_000)

    func snap(duration: TimeInterval?, elapsed: TimeInterval?, rate: Double) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: "Stream", artist: nil, album: nil, artworkData: nil, artworkID: nil,
                           duration: duration, elapsed: elapsed, playbackRate: rate,
                           sourceBundleID: nil, timestamp: t0)
    }

    @Test func encodesSnapshotWithNonFiniteDuration() throws {
        let data = try snap(duration: .nan, elapsed: 5, rate: 1).encoded()
        let back = try NowPlayingSnapshot.decode(data)
        #expect(back.duration == nil)
        #expect(back.elapsed == 5)
    }

    @Test func encodesSnapshotWithInfiniteElapsedAndRate() throws {
        let data = try snap(duration: 100, elapsed: .infinity, rate: .nan).encoded()
        let back = try NowPlayingSnapshot.decode(data)
        #expect(back.duration == 100)
        #expect(back.elapsed == nil)
        #expect(back.playbackRate == 0)
    }

    @Test func sanitizedLeavesFiniteValuesAlone() {
        let s = snap(duration: 100, elapsed: 5, rate: 1)
        #expect(s.sanitized() == s)
    }

    @Test func roundTripsFiniteSnapshot() throws {
        let s = snap(duration: 100, elapsed: 5, rate: 1)
        #expect(try NowPlayingSnapshot.decode(s.encoded()) == s)
    }
}
