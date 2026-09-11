import Testing
import Foundation
@testable import NowPlayingClient
import NowPlayingShared

/// The AppleScript payload is newline-separated, in this order:
/// title, artist, album, durationMS, positionMS, playerState, artworkURL, trackID.
/// Both apps report integer milliseconds so the text form carries no decimal separator
/// (a comma-decimal locale would otherwise break `Double(_:)`).
struct AppleScriptParsingTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func parsesSpotifyIntegerMilliseconds() {
        let fields = ["Bohemian Rhapsody", "Queen", "A Night at the Opera",
                      "354000", "12500", "playing",
                      "https://i.scdn.co/image/abc", "spotify:track:xyz"]
        let s = AppleScriptNowPlayingSource.parseSnapshot(fields: fields,
                                                          app: AppleScriptNowPlayingSource.spotify,
                                                          now: now)
        #expect(s?.title == "Bohemian Rhapsody")
        #expect(s?.artist == "Queen")
        #expect(s?.album == "A Night at the Opera")
        #expect(s?.duration == 354)
        #expect(s?.elapsed == 12.5)
        #expect(s?.playbackRate == 1)
        #expect(s?.artworkID == "https://i.scdn.co/image/abc")
        #expect(s?.sourceBundleID == AppleScriptNowPlayingSource.spotify)
        #expect(s?.timestamp == now)
    }

    @Test func parsesMusicIntegerMilliseconds() {
        // Music has no artwork URL, so the track id becomes the artwork identity.
        let fields = ["Redbone", "Childish Gambino", "Awaken, My Love!",
                      "326000", "0", "paused", "", "12345"]
        let s = AppleScriptNowPlayingSource.parseSnapshot(fields: fields,
                                                          app: AppleScriptNowPlayingSource.music,
                                                          now: now)
        #expect(s?.duration == 326)
        #expect(s?.elapsed == 0)
        #expect(s?.playbackRate == 0)
        #expect(s?.artworkID == "12345")
        #expect(s?.sourceBundleID == AppleScriptNowPlayingSource.music)
    }

    @Test func rejectsShortFieldList() {
        let fields = ["Title", "Artist", "Album", "1000"]
        #expect(AppleScriptNowPlayingSource.parseSnapshot(fields: fields,
                                                          app: AppleScriptNowPlayingSource.music,
                                                          now: now) == nil)
    }

    @Test func nonIntegerNumbersBecomeNilRatherThanZero() {
        let fields = ["Title", "Artist", "Album", "326,5", "not a number", "playing", "", "id"]
        let s = AppleScriptNowPlayingSource.parseSnapshot(fields: fields,
                                                          app: AppleScriptNowPlayingSource.music,
                                                          now: now)
        #expect(s?.duration == nil)
        #expect(s?.elapsed == nil)
        #expect(s?.title == "Title")
    }
}

struct AppleScriptErrorThrottleTests {
    @Test func logsOncePerErrorNumberPerWindow() {
        let throttle = AppleScriptErrorThrottle(window: 60)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(throttle.shouldLog(errorNumber: -1743, now: t0))
        #expect(!throttle.shouldLog(errorNumber: -1743, now: t0.addingTimeInterval(2)))
        #expect(!throttle.shouldLog(errorNumber: -1743, now: t0.addingTimeInterval(59)))
        #expect(throttle.shouldLog(errorNumber: -1743, now: t0.addingTimeInterval(61)))
    }

    @Test func distinctErrorNumbersAreThrottledSeparately() {
        let throttle = AppleScriptErrorThrottle(window: 60)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(throttle.shouldLog(errorNumber: -1743, now: t0))
        #expect(throttle.shouldLog(errorNumber: -1728, now: t0))
        #expect(!throttle.shouldLog(errorNumber: -1728, now: t0.addingTimeInterval(1)))
    }
}
