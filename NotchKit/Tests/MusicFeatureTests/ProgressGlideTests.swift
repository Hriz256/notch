import Testing
import Foundation
import SwiftUI
@testable import MusicFeature

/// The rule that decides whether the progress fill glides, eases or cuts. The bar must never
/// run backwards on a track change, and must never *step* while a track plays.
struct ProgressGlideTests {
    private func sample(_ elapsed: TimeInterval, _ track: String? = "one") -> ProgressGlide.Sample {
        ProgressGlide.Sample(elapsed: elapsed, trackID: track)
    }

    @Test func oneTickGlides() {
        #expect(ProgressGlide.classify(from: sample(12), to: sample(13)) == .glide)
    }

    /// A late timer or a busy main thread stretches the second; that is still a tick.
    @Test func aStretchedTickStillGlides() {
        #expect(ProgressGlide.classify(from: sample(12), to: sample(13.4)) == .glide)
    }

    @Test func aForwardJumpIsASeek() {
        #expect(ProgressGlide.classify(from: sample(12), to: sample(90)) == .seek)
    }

    /// Scrubbing back inside the same track is a seek and does animate — it is the user's own
    /// move. It is the *track change* below that must not animate.
    @Test func aBackwardJumpInsideTheTrackIsASeek() {
        #expect(ProgressGlide.classify(from: sample(90), to: sample(12)) == .seek)
    }

    @Test func aTrackChangeCuts() {
        #expect(ProgressGlide.classify(from: sample(178, "one"), to: sample(0, "two")) == .cut)
    }

    /// Even a track change that happens to land further along must cut: the new track's 5 s is
    /// not the old track's 5 s, and interpolating between them is meaningless.
    @Test func aTrackChangeCutsEvenWhenItMovesForward() {
        #expect(ProgressGlide.classify(from: sample(3, "one"), to: sample(4, "two")) == .cut)
    }

    /// The case that made the fill sweep backwards across the whole bar: a live album where
    /// consecutive tracks share a title and a cover and differ only by artist. `trackKey`
    /// carries the artist, so this is a track change and it cuts.
    @Test func anArtistOnlyTrackChangeCuts() {
        let before = ProgressGlide.Sample(elapsed: 174, trackID: "Intro\u{1F}Ann\u{1F}art-7")
        let after = ProgressGlide.Sample(elapsed: 0, trackID: "Intro\u{1F}Bo\u{1F}art-7")
        #expect(ProgressGlide.classify(from: before, to: after) == .cut)
    }

    /// A paused island still ticks (the timer is what resumes cleanly); the value does not
    /// move, and neither may the fill.
    @Test func aTickThatDoesNotMoveCuts() {
        #expect(ProgressGlide.classify(from: sample(41), to: sample(41)) == .cut)
    }

    @Test func aCutHasNoAnimationAndTheOthersDo() {
        #expect(ProgressGlide.cut.animation == nil)
        #expect(ProgressGlide.glide.animation != nil)
        #expect(ProgressGlide.seek.animation != nil)
    }

    /// The glide has to cover exactly one tick, or the fill arrives early and stalls.
    @Test func theGlideIsTimedToTheTick() {
        #expect(ProgressGlide.tickInterval == 1)
        #expect(ProgressGlide.maxTickStep > ProgressGlide.tickInterval)
        #expect(ProgressGlide.seekDuration == 0.2)
    }
}
