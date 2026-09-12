import Testing
@testable import IslandCore

/// Mirrors `NowPlayingSharedTests.TimeFormattingTests`: the two copies must stay in step.
@Suite("IslandCore time formatting")
struct IslandTimeFormattingTests {
    @Test func formatsMinutesAndPaddedSeconds() {
        #expect(TimeFormatting.mmss(0) == "0:00")
        #expect(TimeFormatting.mmss(65) == "1:05")
        #expect(TimeFormatting.mmss(600) == "10:00")
        #expect(TimeFormatting.mmss(3725) == "62:05")
    }

    @Test func truncatesAndClampsBelowZero() {
        #expect(TimeFormatting.mmss(59.9) == "0:59")
        #expect(TimeFormatting.mmss(-3) == "0:00")
    }

    /// A live stream reports nonsense durations; formatting one must not trap in `Int(_:)`.
    @Test func nonsenseDurationsFormatAsZero() {
        #expect(TimeFormatting.mmss(.nan) == "0:00")
        #expect(TimeFormatting.mmss(.infinity) == "0:00")
        #expect(TimeFormatting.mmss(1e30) == "0:00")
        #expect(TimeFormatting.mmss(.greatestFiniteMagnitude) == "0:00")
    }
}
