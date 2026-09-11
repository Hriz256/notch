import Testing
import Foundation
@testable import CodeAgentShared

@Suite struct ResetFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func string(afterHours hours: Double, minutes: Double = 0, seconds: Double = 0) -> String {
        ResetFormatter.string(until: now.addingTimeInterval(hours * 3600 + minutes * 60 + seconds), now: now)
    }

    @Test func hoursAndMinutes() {
        #expect(string(afterHours: 4, minutes: 18) == "4h 18m")
    }

    @Test func daysAndHours() {
        #expect(string(afterHours: 6 * 24 + 13, minutes: 42) == "6d 13h")
    }

    @Test func minutesOnly() {
        #expect(string(afterHours: 0, minutes: 12, seconds: 30) == "12m")
    }

    @Test func lessThanAMinuteIsZeroMinutes() {
        #expect(string(afterHours: 0, minutes: 0, seconds: 30) == "0m")
    }

    @Test func exactlyOneHourDropsToHourForm() {
        #expect(string(afterHours: 1) == "1h 0m")
    }

    @Test func exactlyOneDayDropsToDayForm() {
        #expect(string(afterHours: 24) == "1d 0h")
    }

    @Test func pastIsNow() {
        #expect(string(afterHours: -2) == "now")
        #expect(ResetFormatter.string(until: now, now: now) == "now")
    }
}
