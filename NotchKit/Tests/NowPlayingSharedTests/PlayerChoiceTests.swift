import Testing
import Foundation
@testable import NowPlayingShared

struct PlayerChoiceTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let spotify = "com.spotify.client"
    let chrome = "com.google.Chrome"

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func c(_ id: String, _ playing: Bool) -> PlayerChoice.Candidate { .init(id: id, isPlaying: playing) }

    @Test func nothingPlayingFollowsTheElectedPlayer() {
        var choice = PlayerChoice()
        let d = choice.decide([c(spotify, false), c(chrome, false)], elected: chrome, now: t0)
        #expect(d == .init(playerID: chrome, recheckAt: nil))
    }

    /// The reported bug: a paused Chrome tab is elected while Spotify plays.
    @Test func aPlayingPlayerBeatsAPausedElectedOne() {
        var choice = PlayerChoice()
        let d = choice.decide([c(chrome, false), c(spotify, true)], elected: chrome, now: t0)
        #expect(d.playerID == spotify)
    }

    @Test func bothPlayingWithNoHistoryFollowsTheElectedPlayer() {
        var choice = PlayerChoice()
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: t0).playerID == chrome)
    }

    @Test func aBriefSoundDoesNotTakeTheIsland() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        let during = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10))
        #expect(during == .init(playerID: spotify, recheckAt: at(13)))
        let after = choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: at(10.2))
        #expect(after == .init(playerID: spotify, recheckAt: nil))
    }

    @Test func aNewcomerTakesTheIslandAfterPlayingForTheDelay() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10)).playerID == spotify)
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(12.9)).playerID == spotify)
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(13)) == .init(playerID: chrome, recheckAt: nil))
    }

    @Test func aNewcomerThatPausesLosesItsHeadStart() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        _ = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10))
        _ = choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: at(12))
        let again = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(14))
        #expect(again == .init(playerID: spotify, recheckAt: at(17)))
    }

    @Test func aPlayerAlreadyPlayingWhenTheShownOneTookOverIsNotAChallenger() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: t0)
        let later = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(60))
        #expect(later == .init(playerID: chrome, recheckAt: nil))
    }

    @Test func pausingTheShownPlayerHandsTheIslandToAPlayingOne() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        _ = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10))
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(13)).playerID == chrome)
        #expect(choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: at(20)).playerID == spotify)
    }

    @Test func nothingPlayingKeepsTheLastShownPlayer() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: t0)
        #expect(choice.decide([c(spotify, false), c(chrome, false)], elected: chrome, now: at(5)).playerID == spotify)
    }

    @Test func theShownPlayerQuittingFallsBackToAPlayingOneThenTheElected() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, false)], elected: spotify, now: t0)
        #expect(choice.decide([c(chrome, true)], elected: chrome, now: at(1)).playerID == chrome)
        var idle = PlayerChoice()
        _ = idle.decide([c(spotify, false)], elected: spotify, now: t0)
        #expect(idle.decide([c(chrome, false), c("com.apple.Music", false)], elected: "com.apple.Music", now: at(1)).playerID == "com.apple.Music")
        #expect(idle.decide([c(chrome, false)], elected: nil, now: at(2)).playerID == chrome)
    }

    @Test func noCandidatesChoosesNothing() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        #expect(choice.decide([], elected: nil, now: at(1)) == .init(playerID: nil, recheckAt: nil))
        #expect(choice.shownID == nil)
    }

    @Test func whenTheShownPlayerQuitsTheLatestStartedPlayingOneWins() {
        var choice = PlayerChoice()
        let music = "com.apple.Music"
        _ = choice.decide([c(music, true)], elected: music, now: t0)
        _ = choice.decide([c(music, true), c(spotify, true)], elected: music, now: at(1))
        _ = choice.decide([c(music, true), c(spotify, true), c(chrome, true)], elected: music, now: at(2))
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: nil, now: at(2.5)).playerID == chrome)
    }

    @Test func equalStartsFallBackToListOrder() {
        var choice = PlayerChoice()
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: nil, now: t0).playerID == spotify)
    }

    @Test func resetForgetsTheShownPlayer() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        choice.reset()
        #expect(choice.shownID == nil)
        #expect(choice.decide([c(spotify, false), c(chrome, false)], elected: chrome, now: at(1)).playerID == chrome)
    }
}
