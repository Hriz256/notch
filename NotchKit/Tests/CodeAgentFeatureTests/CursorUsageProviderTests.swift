import CodeAgentShared
import Foundation
import Testing
@testable import CodeAgentFeature

/// The two reverse-engineered steps between Cursor's database and a usage bar: pulling the
/// account id out of the session JWT, and reading the legacy dashboard payload.
struct CursorUsageProviderTests {

    // MARK: - JWT

    /// Unsigned test tokens: the provider never verifies the signature (this is an id
    /// lookup, not an authorization decision), so the third segment is irrelevant.
    private static func jwt(payload: String) -> String {
        let base64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(base64).signature"
    }

    @Test func userIDIsThePartAfterThePipe() {
        let token = Self.jwt(payload: #"{"sub": "auth0|user_01HXYZ"}"#)
        #expect(CursorUsageProvider.userID(fromJWT: token) == "user_01HXYZ")
    }

    /// Base64url payloads drop the `=` padding and use `-`/`_`; a decoder that does not
    /// restore them returns nothing at all.
    @Test func unpaddedBase64URLPayloadStillDecodes() {
        let token = Self.jwt(payload: #"{"sub": "auth0|u1", "scope": "openid profile"}"#)
        #expect(CursorUsageProvider.userID(fromJWT: token) == "u1")
    }

    @Test func subjectWithoutAPipeIsUsedWhole() {
        let token = Self.jwt(payload: #"{"sub": "user_01HXYZ"}"#)
        #expect(CursorUsageProvider.userID(fromJWT: token) == "user_01HXYZ")
    }

    @Test(arguments: [
        "",
        "notajwt",
        "header.!!!not-base64!!!.signature",
    ])
    func unusableTokensYieldNoUserID(token: String) {
        #expect(CursorUsageProvider.userID(fromJWT: token) == nil)
    }

    @Test func payloadWithoutASubjectYieldsNoUserID() {
        #expect(CursorUsageProvider.userID(fromJWT: Self.jwt(payload: #"{"exp": 1}"#)) == nil)
        #expect(CursorUsageProvider.userID(fromJWT: Self.jwt(payload: #"{"sub": ""}"#)) == nil)
    }

    // MARK: - Usage payload

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ json: String) -> AgentUsage? {
        CursorUsageProvider.parse(Data(json.utf8), now: Self.now)
    }

    @Test func parsesRequestsAsAPercentageAndRollsTheMonthForward() throws {
        let usage = try #require(parse("""
        {"gpt-4": {"numRequests": 125, "maxRequestUsage": 500}, "startOfMonth": "2026-09-01T00:00:00Z"}
        """))

        #expect(usage.agent == .cursor)
        #expect(usage.session?.percent == 25)
        // Cursor bills monthly requests: there is no weekly window and no fixed window length,
        // which is what makes the pace hint meaningless here.
        #expect(usage.weekly == nil)
        #expect(usage.session?.windowLength == nil)
        #expect(usage.fetchedAt == Self.now)

        let reset = try #require(usage.session?.resetsAt)
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: reset)
        #expect(components.year == 2026)
        #expect(components.month == 10)
        #expect(components.day == 1)
    }

    @Test func fractionalSecondsInStartOfMonthAreAccepted() {
        let usage = parse("""
        {"gpt-4": {"numRequests": 1, "maxRequestUsage": 2}, "startOfMonth": "2026-09-01T00:00:00.000Z"}
        """)
        #expect(usage?.session?.resetsAt != nil)
    }

    /// Overage puts `numRequests` past the limit; a bar wider than its track is not a thing.
    @Test func usageOverTheLimitIsClampedToOneHundred() {
        #expect(parse(#"{"gpt-4": {"numRequests": 700, "maxRequestUsage": 500}}"#)?.session?.percent == 100)
    }

    @Test func payloadWithoutAResetDateStillParses() throws {
        let usage = try #require(parse(#"{"gpt-4": {"numRequests": 0, "maxRequestUsage": 500}}"#))
        #expect(usage.session?.percent == 0)
        #expect(usage.session?.resetsAt == nil)
    }

    /// Every shape the endpoint could return without a usable quota collapses to `nil`, which
    /// the provider reports as the one "Sign in to Cursor" message.
    @Test(arguments: [
        "not json",
        "[]",
        #"{"gpt-4": {"numRequests": 1}}"#,
        #"{"gpt-4": {"maxRequestUsage": 500}}"#,
        #"{"gpt-4": {"numRequests": 1, "maxRequestUsage": 0}}"#,
        #"{"other": {"numRequests": 1, "maxRequestUsage": 5}}"#,
    ])
    func unusablePayloadsYieldNothing(json: String) {
        #expect(parse(json) == nil)
    }
}
