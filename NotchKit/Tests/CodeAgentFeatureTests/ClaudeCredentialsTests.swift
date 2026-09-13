import CodeAgentShared
import Foundation
import Testing
@testable import CodeAgentFeature

/// The Keychain lookup is always declined here: reading it for real would pick up the
/// developer's own Claude Code token (and could prompt). Every case goes through the
/// `~/.claude/.credentials.json` fallback in a throwaway home.
final class ClaudeCredentialsTests {
    private let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-credentials-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: home.appendingPathComponent(".claude/.credentials.json"))
    }

    private func load(now: Date = Date()) -> Result<ClaudeCredentials.Token, UsageError> {
        ClaudeCredentials.load(home: home, now: now, keychain: { nil })
    }

    private static let epochMilliseconds: Double = 1_700_000_000_000

    @Test func securityOutputLosesOnlyItsTrailingNewline() {
        let trimmed = ClaudeCredentials.trimmingTrailingNewlines(Data("{\"a\": 1}\n".utf8))
        #expect(String(decoding: trimmed, as: UTF8.self) == "{\"a\": 1}")
        #expect(ClaudeCredentials.trimmingTrailingNewlines(Data("x\r\n\n".utf8)) == Data("x".utf8))
        #expect(ClaudeCredentials.trimmingTrailingNewlines(Data()) == Data())
    }

    @Test func parsesAccessTokenAndMillisecondExpiry() throws {
        try write(#"{"claudeAiOauth": {"accessToken": "sk-ant-oat-x", "expiresAt": 1700000000000}}"#)

        let token = try load(now: Date(timeIntervalSince1970: 1_699_999_000)).get()
        #expect(token.accessToken == "sk-ant-oat-x")
        // Milliseconds, not seconds: a seconds reading would land in 1970.
        #expect(token.expiresAt == Date(timeIntervalSince1970: Self.epochMilliseconds / 1000))
    }

    @Test func payloadWithoutAnExpiryStillYieldsAToken() throws {
        try write(#"{"claudeAiOauth": {"accessToken": "sk-ant-oat-x"}}"#)

        let token = try load().get()
        #expect(token.accessToken == "sk-ant-oat-x")
        #expect(token.expiresAt == nil)
    }

    /// A minute of grace: Claude Code may be mid-refresh, and a spurious "sign in" is worse
    /// than one failed request.
    @Test func tokenInsideTheExpiryGraceIsStillAccepted() throws {
        try write(#"{"claudeAiOauth": {"accessToken": "sk-ant-oat-x", "expiresAt": 1700000000000}}"#)

        let justAfter = Date(timeIntervalSince1970: Self.epochMilliseconds / 1000 + 30)
        #expect((try? load(now: justAfter).get()) != nil)
    }

    @Test func expiredTokenReadsAsNotSignedIn() throws {
        try write(#"{"claudeAiOauth": {"accessToken": "sk-ant-oat-x", "expiresAt": 1700000000000}}"#)

        let wellAfter = Date(timeIntervalSince1970: Self.epochMilliseconds / 1000 + 600)
        #expect(load(now: wellAfter) == .failure(.notSignedIn))
    }

    @Test func missingFileReadsAsNotSignedIn() {
        #expect(load() == .failure(.notSignedIn))
    }

    /// Some 2.1.x installs write an item holding only `mcpOAuth`, and a blank token is no
    /// token at all; neither may be reported as a working session.
    @Test(arguments: [
        #"{"mcpOAuth": {"accessToken": "x"}}"#,
        #"{"claudeAiOauth": {"accessToken": ""}}"#,
        #"{"claudeAiOauth": {}}"#,
        "not json at all",
    ])
    func unusablePayloadsReadAsNotSignedIn(json: String) throws {
        try write(json)
        #expect(load() == .failure(.notSignedIn))
    }
}

/// `Result` equality without spelling out a `case` per assertion.
extension Result: @retroactive Equatable where Success == ClaudeCredentials.Token, Failure == UsageError {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a), .success(let b)):
            a.accessToken == b.accessToken && a.expiresAt == b.expiresAt
        case (.failure(let a), .failure(let b)):
            a == b
        default:
            false
        }
    }
}
