import Testing
@testable import NowPlayingShared

struct TimeFormattingTests {
    @Test func formatsMinutesAndSeconds() {
        #expect(TimeFormatting.mmss(0) == "0:00")
        #expect(TimeFormatting.mmss(65) == "1:05")
        #expect(TimeFormatting.mmss(600) == "10:00")
        #expect(TimeFormatting.mmss(3725) == "62:05")
    }

    @Test func roundsDownAndClampsNegative() {
        #expect(TimeFormatting.mmss(59.9) == "0:59")
        #expect(TimeFormatting.mmss(-3) == "0:00")
    }
}
