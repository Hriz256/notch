import Testing
import Foundation
@testable import CodeAgentShared

@Suite struct ClaudeUsageParserTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    /// Shape of `GET /api/oauth/usage` as of September 2026 (research report §4.1).
    private let septemberSample = """
    {
      "five_hour":            { "utilization": 48.0, "resets_at": "2026-09-12T21:00:00.000000Z" },
      "seven_day":            { "utilization": 64.0, "resets_at": "2026-09-16T09:30:00.000000Z" },
      "seven_day_opus":       { "utilization": 12.5, "resets_at": "2026-09-16T09:30:00.000000Z" },
      "seven_day_sonnet":     { "utilization": 30.0, "resets_at": "2026-09-16T09:30:00.000000Z" },
      "seven_day_oauth_apps": { "utilization": 0.0,  "resets_at": "2026-09-16T09:30:00.000000Z" },
      "extra_usage":          { "is_enabled": true, "monthly_limit": 100, "used_credits": 3,
                                "utilization": 3.0, "currency": "USD" }
    }
    """

    /// Older (April) form: no fractional seconds, `seven_day` absent entirely.
    private let aprilSample = """
    {
      "five_hour": { "utilization": 42.0, "resets_at": "2026-04-03T17:00:00Z" }
    }
    """

    /// Team / API-key account: every window null.
    private let allNullSample = """
    {
      "five_hour": null,
      "seven_day": null,
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "seven_day_oauth_apps": null,
      "limits": []
    }
    """

    /// Newer accounts return only `limits[]`.
    private let limitsOnlySample = """
    {
      "limits": [
        { "kind": "session",       "group": "session", "percent": 33.0,
          "resets_at": "2026-09-12T20:30:00Z", "is_active": true },
        { "kind": "weekly_all",    "group": "weekly",  "percent": 71.5,
          "resets_at": "2026-09-17T00:00:00Z", "is_active": true },
        { "kind": "weekly_scoped", "group": "weekly",  "percent": 9.0,
          "resets_at": "2026-09-17T00:00:00Z",
          "scope": { "model": { "id": "claude-opus-5", "display_name": "Opus 5" } },
          "is_active": true }
      ]
    }
    """

    private func parse(_ json: String) throws -> AgentUsage {
        try ClaudeUsageParser.parse(Data(json.utf8), now: now)
    }

    @Test func parsesSeptemberSample() throws {
        let usage = try parse(septemberSample)
        #expect(usage.agent == .claude)
        #expect(usage.fetchedAt == now)
        #expect(usage.session?.percent == 48.0)
        #expect(usage.weekly?.percent == 64.0)
        // Claude never states window lengths; they are fixed by the plan.
        #expect(usage.session?.windowLength == 18_000)       // 5 h
        #expect(usage.weekly?.windowLength == 604_800)       // 7 d

        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 12
        components.hour = 21; components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(usage.session?.resetsAt == calendar.date(from: components))
        #expect(usage.weekly?.resetsAt != nil)
        #expect(usage.sparkline.isEmpty)
    }

    @Test func parsesAprilSampleWithMissingWeekly() throws {
        let usage = try parse(aprilSample)
        #expect(usage.session?.percent == 42.0)
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_775_235_600))
        #expect(usage.weekly == nil)
    }

    @Test func allNullSampleYieldsNoWindows() throws {
        let usage = try parse(allNullSample)
        #expect(usage.session == nil)
        #expect(usage.weekly == nil)
        #expect(usage.agent == .claude)
        #expect(usage.fetchedAt == now)
    }

    @Test func nullFieldsInsideAWindowYieldNoWindow() throws {
        let usage = try parse("""
        { "five_hour": { "utilization": null, "resets_at": null },
          "seven_day": { "utilization": 12.0, "resets_at": null } }
        """)
        #expect(usage.session == nil)
        #expect(usage.weekly == UsageWindow(percent: 12.0, resetsAt: nil, windowLength: 604_800))
    }

    @Test func parsesLimitsOnlySample() throws {
        let usage = try parse(limitsOnlySample)
        #expect(usage.session?.percent == 33.0)
        #expect(usage.weekly?.percent == 71.5)
        #expect(usage.session?.windowLength == 18_000)       // 5 h
        #expect(usage.weekly?.windowLength == 604_800)       // 7 d
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_789_245_000))
    }

    @Test func limitsTakePrecedenceOverFlatKeys() throws {
        let usage = try parse("""
        { "five_hour": { "utilization": 1.0, "resets_at": "2026-09-12T21:00:00Z" },
          "seven_day": { "utilization": 2.0, "resets_at": "2026-09-16T09:30:00Z" },
          "limits": [ { "kind": "session",    "percent": 80.0, "resets_at": "2026-09-12T20:30:00Z" },
                      { "kind": "weekly_all", "percent": 90.0, "resets_at": "2026-09-17T00:00:00Z" } ] }
        """)
        #expect(usage.session?.percent == 80.0)
        #expect(usage.weekly?.percent == 90.0)
    }

    @Test func fallsBackToFlatKeysWhenLimitsLacksTheKind() throws {
        let usage = try parse("""
        { "five_hour": { "utilization": 1.0, "resets_at": "2026-09-12T21:00:00Z" },
          "limits": [ { "kind": "weekly_all", "percent": 90.0, "resets_at": "2026-09-17T00:00:00Z" } ] }
        """)
        #expect(usage.session?.percent == 1.0)
        #expect(usage.weekly?.percent == 90.0)
    }

    @Test func acceptsEpochSecondsForResetsAt() throws {
        let usage = try parse("""
        { "five_hour": { "utilization": 5.0, "resets_at": 1789588800 } }
        """)
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_789_588_800))
    }

    @Test func acceptsUsedPercentageAlias() throws {
        let usage = try parse("""
        { "five_hour": { "used_percentage": 7.0, "resets_at": 1789588800 },
          "seven_day": { "used_percentage": 9.0, "resets_at": 1789588800 } }
        """)
        #expect(usage.session?.percent == 7.0)
        #expect(usage.weekly?.percent == 9.0)
    }

    @Test func throwsOnNonJSON() {
        #expect(throws: UsageError.unavailable("Unrecognized usage response")) {
            try ClaudeUsageParser.parse(Data("<html>nope</html>".utf8), now: now)
        }
    }

    @Test func throwsOnJSONThatIsNotAnObject() {
        #expect(throws: UsageError.unavailable("Unrecognized usage response")) {
            try ClaudeUsageParser.parse(Data("[1, 2, 3]".utf8), now: now)
        }
    }
}
