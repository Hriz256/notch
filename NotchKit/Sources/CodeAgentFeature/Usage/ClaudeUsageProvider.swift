import CodeAgentShared
import Foundation
import os

/// `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's own OAuth token.
public final class ClaudeUsageProvider: UsageProvider {
    public let agent = Agent.claude

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let timeout: TimeInterval = 15

    private let session: URLSession
    private let home: URL
    private let claudeVersion: @Sendable () async -> String
    private let credentials: @Sendable (URL, Date) -> Result<ClaudeCredentials.Token, UsageError>
    private let logger = UsageLog.logger("claude")

    private struct VersionState: Sendable {
        var resolved: String?
        var isDetecting = false
    }

    private let version = OSAllocatedUnfairLock(initialState: VersionState())

    /// - Parameter credentials: the token lookup, injected so tests never touch the real
    ///   Keychain.
    public init(
        session: URLSession = .shared,
        home: URL,
        claudeVersion: @escaping @Sendable () async -> String,
        credentials: @escaping @Sendable (URL, Date) -> Result<ClaudeCredentials.Token, UsageError>
            = { ClaudeCredentials.load(home: $0, now: $1) }
    ) {
        self.session = session
        self.home = home
        self.claudeVersion = claudeVersion
        self.credentials = credentials
    }

    /// The `User-Agent` version for *this* request, starting the detection if it has not run.
    ///
    /// `claude --version` boots Node and is budgeted 20 s, so awaiting it would push the
    /// first usage bars of every cold launch out by that much. The endpoint only cares that
    /// the UA looks like Claude Code, so the request goes out with the fallback now and the
    /// detected version takes over from the next poll on.
    private func userAgentVersion() -> String {
        let shouldDetect = version.withLock { state -> Bool in
            guard state.resolved == nil, !state.isDetecting else { return false }
            state.isDetecting = true
            return true
        }
        if shouldDetect {
            let detect = claudeVersion
            let version = version
            Task.detached(priority: .utility) {
                let resolved = await detect()
                version.withLock {
                    $0.resolved = resolved
                    $0.isDetecting = false
                }
            }
        }
        return version.withLock { $0.resolved } ?? ClaudeVersionDetector.fallback
    }

    public func fetch() async throws(UsageError) -> AgentUsage {
        let now = Date()
        let token: ClaudeCredentials.Token
        // The default lookup spawns `security` and waits for it: cheap, but not something
        // to do on whichever executor called `fetch`.
        let credentials = self.credentials, home = self.home
        switch await Task.detached(priority: .utility) { credentials(home, now) }.value {
        case .success(let value): token = value
        case .failure(let error): throw error
        }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = Self.timeout
        // Quota is the one thing that must never be read out of a cache: a stale 200 would
        // draw a bar that is minutes or hours behind the real window.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Mandatory: without it the request lands in a punishing rate-limit bucket that
        // returns sticky 429s with no Retry-After (claude-code#31637).
        request.setValue("claude-code/\(userAgentVersion())", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // `localizedDescription` never carries request headers, so this cannot leak the token.
            logger.error("usage request failed: \(error.localizedDescription, privacy: .public)")
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Malformed response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw UsageError.notSignedIn
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.network("HTTP \(http.statusCode)")
        }

        do {
            return try ClaudeUsageParser.parse(data, now: now)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.unavailable("Unrecognized usage response")
        }
    }
}

/// Resolves the installed Claude Code version once per process, for the `User-Agent`.
public enum ClaudeVersionDetector {
    /// Used when `claude` is absent or its output is unrecognizable. Any plausible
    /// version keeps the request out of the punitive bucket.
    public static let fallback = "2.1.0"

    private actor Cache {
        static let shared = Cache()
        private var value: String?

        func version(_ produce: @Sendable () async -> String) async -> String {
            if let value { return value }
            let resolved = await produce()
            value = resolved
            return resolved
        }
    }

    public static func detect(home: URL = URL(fileURLWithPath: NSHomeDirectory())) async -> String {
        await Cache.shared.version { await probe(home: home) }
    }

    static func probe(home: URL) async -> String {
        guard let executable = await ExecutableLocator.find("claude", home: home),
              let output = await ProcessRunner.output(
                  executable: executable,
                  arguments: ["--version"],
                  // `claude --version` boots Node: ~10 s on a cold machine, so a 10 s
                  // budget would fall back to the placeholder UA about half the time.
                  timeout: .seconds(20)
              ),
              let semver = semver(in: output)
        else {
            UsageLog.logger("claude").debug("claude --version unavailable, using fallback UA")
            return fallback
        }
        return semver
    }

    /// `claude --version` prints e.g. `2.1.258 (Claude Code)`.
    static func semver(in output: String) -> String? {
        let pattern = /([0-9]+\.[0-9]+\.[0-9]+)/
        guard let match = output.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }
}
