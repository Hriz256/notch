import Testing
import Foundation
@testable import CodeAgentShared

@Suite struct ClaudeUsageLogTests {
    /// A real `~/.claude/projects/**/*.jsonl` assistant line (research report §4.1).
    private let assistantLine = """
    {"type":"assistant","timestamp":"2026-09-11T17:02:43.318Z","sessionId":"39d207ef",\
    "requestId":"req_011C","version":"2.1.260","cwd":"/Users/x/p","gitBranch":"main",\
    "message":{"model":"claude-fable-5-1","id":"msg_1","usage":{"input_tokens":2,\
    "cache_creation_input_tokens":28078,"cache_read_input_tokens":41039,"output_tokens":234,\
    "output_tokens_details":{"thinking_tokens":129},\
    "cache_creation":{"ephemeral_1h_input_tokens":28078,"ephemeral_5m_input_tokens":0},\
    "service_tier":"standard"}}}
    """

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - entry(fromLine:)

    @Test func sumsAllTokenBuckets() throws {
        let entry = try #require(ClaudeUsageLog.entry(fromLine: assistantLine))
        // 2 input + 234 output + 28078 cache creation (nested) + 41039 cache read
        #expect(entry.tokens == 69_353)
        #expect(entry.key == "msg_1:req_011C")
        #expect(entry.timestamp == date("2026-09-11T17:02:43.318Z"))
    }

    @Test func fallsBackToFlatCacheCreationWhenNestedIsAbsent() throws {
        let entry = try #require(ClaudeUsageLog.entry(fromLine: """
        {"type":"assistant","timestamp":"2026-09-11T17:02:43.318Z","requestId":"req_2",\
        "message":{"id":"msg_2","usage":{"input_tokens":1,"output_tokens":2,\
        "cache_creation_input_tokens":10,"cache_read_input_tokens":100}}}
        """))
        #expect(entry.tokens == 113)
        #expect(entry.key == "msg_2:req_2")
    }

    @Test func nestedCacheCreationWinsOverFlatField() throws {
        let entry = try #require(ClaudeUsageLog.entry(fromLine: """
        {"type":"assistant","timestamp":"2026-09-11T17:02:43.318Z",\
        "message":{"id":"msg_3","usage":{"input_tokens":0,"output_tokens":0,\
        "cache_creation_input_tokens":999,\
        "cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":7},\
        "cache_read_input_tokens":0}}}
        """))
        #expect(entry.tokens == 12)
    }

    @Test func keyIsNilWhenEitherHalfIsMissing() throws {
        let noRequest = try #require(ClaudeUsageLog.entry(fromLine: """
        {"type":"assistant","timestamp":"2026-09-11T17:02:43.318Z",\
        "message":{"id":"msg_4","usage":{"input_tokens":5,"output_tokens":5}}}
        """))
        #expect(noRequest.key == nil)
        #expect(noRequest.tokens == 10)

        let noMessageID = try #require(ClaudeUsageLog.entry(fromLine: """
        {"type":"assistant","timestamp":"2026-09-11T17:02:43.318Z","requestId":"req_5",\
        "message":{"usage":{"input_tokens":5,"output_tokens":5}}}
        """))
        #expect(noMessageID.key == nil)
    }

    @Test func nonAssistantLinesAreIgnored() {
        #expect(ClaudeUsageLog.entry(fromLine: """
        {"type":"user","timestamp":"2026-09-11T17:02:43.318Z",\
        "message":{"id":"m","usage":{"input_tokens":9,"output_tokens":9}}}
        """) == nil)
    }

    @Test func linesWithoutUsageAreIgnored() {
        #expect(ClaudeUsageLog.entry(fromLine: """
        {"type":"assistant","timestamp":"2026-09-11T17:02:43.318Z","message":{"id":"m"}}
        """) == nil)
    }

    @Test func malformedLinesAreIgnored() {
        #expect(ClaudeUsageLog.entry(fromLine: "") == nil)
        #expect(ClaudeUsageLog.entry(fromLine: "not json at all") == nil)
        #expect(ClaudeUsageLog.entry(fromLine: """
        {"type":"assistant","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        """) == nil)
    }

    @Test func acceptsTimestampsWithoutFractionalSeconds() throws {
        let entry = try #require(ClaudeUsageLog.entry(fromLine: """
        {"type":"assistant","timestamp":"2026-09-11T17:02:43Z",\
        "message":{"id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        """))
        #expect(entry.timestamp == ISO8601DateFormatter().date(from: "2026-09-11T17:02:43Z"))
    }

    // MARK: - dailyTotals

    @Test func bucketsIntoSevenCalendarDaysOldestFirst() {
        let end = date("2026-09-11T17:00:00.000Z")
        let entries = [
            ClaudeUsageLog.Entry(key: nil, tokens: 100, timestamp: date("2026-09-11T01:00:00.000Z")),
            ClaudeUsageLog.Entry(key: nil, tokens: 50, timestamp: date("2026-09-11T23:00:00.000Z")),
            ClaudeUsageLog.Entry(key: nil, tokens: 7, timestamp: date("2026-09-05T12:00:00.000Z")),
            ClaudeUsageLog.Entry(key: nil, tokens: 3, timestamp: date("2026-09-08T12:00:00.000Z")),
        ]
        let totals = ClaudeUsageLog.dailyTotals(entries: entries, days: 7, endingAt: end, calendar: utc)
        #expect(totals == [7, 0, 0, 3, 0, 0, 150])
    }

    @Test func dropsEntriesOutsideTheWindow() {
        let end = date("2026-09-11T17:00:00.000Z")
        let entries = [
            ClaudeUsageLog.Entry(key: nil, tokens: 999, timestamp: date("2026-09-01T12:00:00.000Z")),
            ClaudeUsageLog.Entry(key: nil, tokens: 888, timestamp: date("2026-09-20T12:00:00.000Z")),
            ClaudeUsageLog.Entry(key: nil, tokens: 5, timestamp: date("2026-09-11T12:00:00.000Z")),
        ]
        #expect(ClaudeUsageLog.dailyTotals(entries: entries, days: 7, endingAt: end, calendar: utc)
                == [0, 0, 0, 0, 0, 0, 5])
    }

    @Test func duplicateKeysKeepTheLastEntry() {
        let end = date("2026-09-11T17:00:00.000Z")
        let entries = [
            ClaudeUsageLog.Entry(key: "msg_1:req_1", tokens: 10, timestamp: date("2026-09-10T12:00:00.000Z")),
            ClaudeUsageLog.Entry(key: "msg_1:req_1", tokens: 40, timestamp: date("2026-09-11T12:00:00.000Z")),
            ClaudeUsageLog.Entry(key: "msg_2:req_2", tokens: 5, timestamp: date("2026-09-11T13:00:00.000Z")),
        ]
        let totals = ClaudeUsageLog.dailyTotals(entries: entries, days: 7, endingAt: end, calendar: utc)
        #expect(totals == [0, 0, 0, 0, 0, 0, 45])
    }

    @Test func keylessEntriesAreNeverDeduplicated() {
        let end = date("2026-09-11T17:00:00.000Z")
        let stamp = date("2026-09-11T12:00:00.000Z")
        let entries = (0..<3).map { _ in ClaudeUsageLog.Entry(key: nil, tokens: 10, timestamp: stamp) }
        #expect(ClaudeUsageLog.dailyTotals(entries: entries, days: 7, endingAt: end, calendar: utc).last == 30)
    }

    @Test func respectsTheCalendarsDayBoundaries() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let end = date("2026-09-11T17:00:00.000Z")           // 10:00 Sept 11 Pacific
        // 02:00 UTC Sept 11 is 19:00 Sept 10 Pacific.
        let entry = ClaudeUsageLog.Entry(key: nil, tokens: 12, timestamp: date("2026-09-11T02:00:00.000Z"))
        let utcTotals = ClaudeUsageLog.dailyTotals(entries: [entry], days: 7, endingAt: end, calendar: utc)
        let pacificTotals = ClaudeUsageLog.dailyTotals(entries: [entry], days: 7, endingAt: end, calendar: pacific)
        #expect(utcTotals == [0, 0, 0, 0, 0, 0, 12])
        #expect(pacificTotals == [0, 0, 0, 0, 0, 12, 0])
    }

    @Test func emptyInputStillReturnsRequestedLength() {
        let totals = ClaudeUsageLog.dailyTotals(
            entries: [], days: 7, endingAt: date("2026-09-11T17:00:00.000Z"), calendar: utc)
        #expect(totals == [0, 0, 0, 0, 0, 0, 0])
        #expect(ClaudeUsageLog.dailyTotals(
            entries: [], days: 0, endingAt: date("2026-09-11T17:00:00.000Z"), calendar: utc).isEmpty)
    }
}
