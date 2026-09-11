import Testing
import Foundation
@testable import CodeAgentShared

@Suite struct CodexRateLimitParserTests {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    /// The `account/rateLimits/read` response captured live against codex-cli 0.146.0
    /// (research report §4.2), verbatim.
    private let capturedResponse = """
    {"id":2,"result":{
      "rateLimits":{ "limitId":"codex","limitName":null,
        "primary":{"usedPercent":77,"windowDurationMins":43200,"resetsAt":1790147743},
        "secondary":null,
        "credits":{"hasCredits":false,"unlimited":false,"balance":null},
        "individualLimit":null,"spendControlReached":false,
        "planType":"free","rateLimitReachedType":null },
      "rateLimitsByLimitId":{ "codex":{
        "primary":{"usedPercent":77,"windowDurationMins":43200,"resetsAt":1790147743} } },
      "rateLimitResetCredits":{ "availableCount":1, "credits":[
        {"id":"RateLimitResetCredit_1","resetType":"codexRateLimits","status":"available",
         "grantedAt":1789000000, "expiresAt":1791000000, "title":"Full reset (Monthly)",
         "description":"Thanks for using Codex!"}]}}}
    """

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func parsesCapturedAppServerResponse() throws {
        let usage = try #require(CodexRateLimitParser.parse(object(capturedResponse), now: now))
        #expect(usage.agent == .codex)
        #expect(usage.fetchedAt == now)
        #expect(usage.planLabel == "free")
        // windowDurationMins 43 200 = 30 days: the Codex "primary" window is not always 5 h.
        #expect(usage.session == UsageWindow(
            percent: 77,
            resetsAt: Date(timeIntervalSince1970: 1_790_147_743),
            windowLength: 43_200 * 60
        ))
        #expect(usage.weekly == nil)
        #expect(usage.sparkline.isEmpty)
    }

    @Test func parsesBothWindows() throws {
        let usage = try #require(CodexRateLimitParser.parse(object("""
        {"result":{"rateLimits":{
          "primary":{"usedPercent":4,"windowDurationMins":300,"resetsAt":1782397669},
          "secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1782984469},
          "planType":"prolite"}}}
        """), now: now))
        #expect(usage.session?.percent == 4)
        #expect(usage.weekly?.percent == 1)
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_782_984_469))
        #expect(usage.session?.windowLength == 18_000)       // 300 min
        #expect(usage.weekly?.windowLength == 604_800)       // 10 080 min
        #expect(usage.planLabel == "prolite")
    }

    @Test func acceptsSnakeCaseRolloutSpelling() throws {
        let usage = try #require(CodexRateLimitParser.parse(object("""
        {"rate_limits":{
          "primary":{"used_percent":4.0,"window_minutes":300,"resets_at":1782397669},
          "secondary":{"used_percent":1.5,"window_minutes":10080,"reset_at":1782984469},
          "plan_type":"plus"}}
        """), now: now))
        #expect(usage.session == UsageWindow(
            percent: 4.0,
            resetsAt: Date(timeIntervalSince1970: 1_782_397_669),
            windowLength: 300 * 60
        ))
        #expect(usage.weekly?.percent == 1.5)
        #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_782_984_469))
        #expect(usage.planLabel == "plus")
    }

    @Test func acceptsISOResetTimestamps() throws {
        let usage = try #require(CodexRateLimitParser.parse(object("""
        {"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,
                                            "resetsAt":"2026-09-12T20:30:00Z"}}}}
        """), now: now))
        #expect(usage.session?.resetsAt == Date(timeIntervalSince1970: 1_789_245_000))
    }

    @Test func nullWindowsStillProduceUsage() throws {
        let usage = try #require(CodexRateLimitParser.parse(object("""
        {"result":{"rateLimits":{"primary":null,"secondary":null,"planType":null}}}
        """), now: now))
        #expect(usage.session == nil)
        #expect(usage.weekly == nil)
        #expect(usage.planLabel == nil)
    }

    @Test func missingRateLimitsPayloadIsNil() throws {
        #expect(CodexRateLimitParser.parse(try object("""
        {"id":2,"result":{"rateLimitResetCredits":{"availableCount":0}}}
        """), now: now) == nil)
        #expect(CodexRateLimitParser.parse(try object("""
        {"id":1,"result":{"userAgent":"NotchResearch/0.146.0"}}
        """), now: now) == nil)
    }

    @Test func windowWithoutPercentIsNil() throws {
        let usage = try #require(CodexRateLimitParser.parse(object("""
        {"result":{"rateLimits":{"primary":{"windowDurationMins":300,"resetsAt":1782397669}}}}
        """), now: now))
        #expect(usage.session == nil)
    }
}
