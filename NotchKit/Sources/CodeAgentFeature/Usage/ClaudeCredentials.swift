import CodeAgentShared
import Foundation
import Security

/// Reads (never writes) Claude Code's OAuth token.
///
/// Claude Code owns the `Claude Code-credentials` Keychain item and rewrites it on every
/// refresh; a second writer racing it is how a user gets logged out. Notch therefore only
/// reads, and reports `.notSignedIn` rather than attempting a refresh.
///
/// Nothing here ever logs the token or any substring of it.
public enum ClaudeCredentials {
    public struct Token: Sendable {
        public var accessToken: String
        /// From `claudeAiOauth.expiresAt` (epoch **milliseconds**); absent on old payloads.
        public var expiresAt: Date?

        public init(accessToken: String, expiresAt: Date?) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
        }
    }

    /// macOS generic-password service name, built by the CLI as `"Claude Code" + "-credentials"`.
    static let keychainService = "Claude Code-credentials"

    /// Grace period past `expiresAt` before the token counts as dead — Claude Code may be
    /// mid-refresh, and a spurious "sign in" is worse than one failed request.
    private static let expiryGrace: TimeInterval = 60

    /// Keychain first, then the pre-migration `~/.claude/.credentials.json` fallback.
    public static func load(home: URL, now: Date) -> Result<Token, UsageError> {
        let token = keychainPayload().flatMap(parse(payload:))
            ?? filePayload(home: home).flatMap(parse(payload:))

        guard let token else { return .failure(.notSignedIn) }
        if let expiresAt = token.expiresAt, expiresAt < now.addingTimeInterval(-expiryGrace) {
            return .failure(.notSignedIn)
        }
        return .success(token)
    }

    // MARK: - Sources

    private static func keychainPayload() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func filePayload(home: URL) -> Data? {
        try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))
    }

    // MARK: - Parsing

    /// Some 2.1.x installs write an item holding only `mcpOAuth` — treated as "not signed in".
    private static func parse(payload: Data) -> Token? {
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else { return nil }

        let expiresAt = (oauth["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Token(accessToken: accessToken, expiresAt: expiresAt)
    }
}
