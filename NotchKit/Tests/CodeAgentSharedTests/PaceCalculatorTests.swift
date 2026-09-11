import Testing
import Foundation
@testable import CodeAgentShared

@Suite struct PaceCalculatorTests {
    private let fiveHours: TimeInterval = 5 * 60 * 60
    private let sevenDays: TimeInterval = 7 * 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    @Test func lowUsageEarlyInWindowIsGood() {
        // 15 % elapsed of a 5 h window -> 45 min in, 4 h 15 m left.
        let resetsAt = now.addingTimeInterval(fiveHours * 0.85)
        #expect(PaceCalculator.pace(percent: 8, resetsAt: resetsAt, windowLength: fiveHours, now: now) == .good)
    }

    @Test func highUsageEarlyInWindowIsSlowDown() {
        let resetsAt = now.addingTimeInterval(fiveHours * 0.90)
        #expect(PaceCalculator.pace(percent: 36, resetsAt: resetsAt, windowLength: fiveHours, now: now) == .slowDown)
    }

    @Test func nilResetsAtGivesNoVerdict() {
        #expect(PaceCalculator.pace(percent: 99, resetsAt: nil, windowLength: fiveHours, now: now) == nil)
    }

    @Test func toleranceBandIsTenPointsAndExclusive() {
        // 50 % elapsed -> threshold is 60 %.
        let resetsAt = now.addingTimeInterval(fiveHours * 0.5)
        #expect(PaceCalculator.pace(percent: 60, resetsAt: resetsAt, windowLength: fiveHours, now: now) == .good)
        #expect(PaceCalculator.pace(percent: 60.01, resetsAt: resetsAt, windowLength: fiveHours, now: now) == .slowDown)
    }

    @Test func elapsedFractionClampsWhenResetIsInThePast() {
        // Fully elapsed -> threshold 110 %, nothing can exceed it.
        let resetsAt = now.addingTimeInterval(-3600)
        #expect(PaceCalculator.pace(percent: 100, resetsAt: resetsAt, windowLength: fiveHours, now: now) == .good)
    }

    @Test func elapsedFractionClampsWhenResetIsBeyondTheWindow() {
        // Reset further out than the window length -> treat as 0 % elapsed, threshold 10 %.
        let resetsAt = now.addingTimeInterval(fiveHours * 2)
        #expect(PaceCalculator.pace(percent: 10, resetsAt: resetsAt, windowLength: fiveHours, now: now) == .good)
        #expect(PaceCalculator.pace(percent: 11, resetsAt: resetsAt, windowLength: fiveHours, now: now) == .slowDown)
    }

    @Test func weeklyWindowUsesItsOwnLength() {
        // Two days into a seven day window ~ 28.6 % elapsed -> threshold ~38.6 %.
        let resetsAt = now.addingTimeInterval(sevenDays - 2 * 24 * 60 * 60)
        #expect(PaceCalculator.pace(percent: 30, resetsAt: resetsAt, windowLength: sevenDays, now: now) == .good)
        #expect(PaceCalculator.pace(percent: 64, resetsAt: resetsAt, windowLength: sevenDays, now: now) == .slowDown)
    }

    @Test func nonPositiveWindowLengthGivesNoVerdict() {
        #expect(PaceCalculator.pace(percent: 50, resetsAt: now, windowLength: 0, now: now) == nil)
    }
}
