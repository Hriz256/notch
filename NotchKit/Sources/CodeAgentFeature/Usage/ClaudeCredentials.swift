import CodeAgentShared
import Foundation

/// Reads (never writes) Claude Code's OAuth token.
///
/// Claude Code owns the `Claude Code-credentials` Keychain item and rewrites it on every
/// refresh; a second writer racing it is how a user gets logged out. Notch therefore only
/// reads, and reports `.notSignedIn` rather than attempting a refresh.
///
/// The read goes through `/usr/bin/security`, not `SecItemCopyMatching`. The item is
/// created by that tool, so its ACL trusts the tool outright, whereas an app of our own is
/// admitted by cdhash — "Always Allow" survives exactly until the next build, and then macOS
/// asks for the login password again. Spawning the tool is what Claude Code itself does, and
/// it never prompts.
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
        load(home: home, now: now, keychain: keychainPayload)
    }

    /// - Parameter keychain: the Keychain lookup, injected so tests can decline it. A test
    ///   that read the real Keychain would pick up the developer's own Claude Code token.
    static func load(
        home: URL,
        now: Date,
        keychain: () -> Data?
    ) -> Result<Token, UsageError> {
        let token = keychain().flatMap(parse(payload:))
            ?? filePayload(home: home).flatMap(parse(payload:))

        guard let token else { return .failure(.notSignedIn) }
        if let expiresAt = token.expiresAt, expiresAt < now.addingTimeInterval(-expiryGrace) {
            return .failure(.notSignedIn)
        }
        return .success(token)
    }

    // MARK: - Sources

    /// `security find-generic-password -w` prints the secret followed by a newline.
    /// Blocking, so callers keep it off the main actor. A hung tool (a prompt after all)
    /// is killed after ``securityTimeout`` rather than wedging the poll for good.
    private static func keychainPayload() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + securityTimeout, execute: watchdog)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return trimmingTrailingNewlines(output)
    }

    private static let securityTimeout: TimeInterval = 10

    static func trimmingTrailingNewlines(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex, data[end - 1] == UInt8(ascii: "\n") || data[end - 1] == UInt8(ascii: "\r") {
            end -= 1
        }
        return data[data.startIndex..<end]
    }

    private static func filePayload(home: URL) -> Data? {
        try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))
    }

    // MARK: - Parsing

    /// Some 2.1.x installs write an item holding only `mcpOAuth` — treated as "not signed in".
    static func parse(payload: Data) -> Token? {
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
