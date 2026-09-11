import Testing
import Foundation
@testable import NowPlayingShared

struct PlaybackProgressTrackerTests {
    let t0 = Date(timeIntervalSince1970: 5_000)

    func snap(elapsed: TimeInterval?, rate: Double, duration: TimeInterval? = 100) -> NowPlayingSnapshot {
        NowPlayingSnapshot(title: "x", artist: nil, album: nil, artworkData: nil, artworkID: nil,
                           duration: duration, elapsed: elapsed, playbackRate: rate,
                           sourceBundleID: nil, timestamp: t0)
    }

    @Test func playingAdvances() {
        #expect(PlaybackProgressTracker.elapsed(for: snap(elapsed: 10, rate: 1), at: t0.addingTimeInterval(4)) == 14)
    }

    @Test func pausedHolds() {
        #expect(PlaybackProgressTracker.elapsed(for: snap(elapsed: 10, rate: 0), at: t0.addingTimeInterval(60)) == 10)
    }

    @Test func clampsAtDuration() {
        #expect(PlaybackProgressTracker.elapsed(for: snap(elapsed: 95, rate: 1), at: t0.addingTimeInterval(30)) == 100)
    }

    @Test func nilElapsedIsNil() {
        #expect(PlaybackProgressTracker.elapsed(for: snap(elapsed: nil, rate: 1), at: t0) == nil)
    }

    @Test func neverNegative() {
        #expect(PlaybackProgressTracker.elapsed(for: snap(elapsed: 2, rate: 1), at: t0.addingTimeInterval(-10)) == 0)
    }
}
