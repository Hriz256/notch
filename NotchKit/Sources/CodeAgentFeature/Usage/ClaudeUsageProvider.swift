import CodeAgentShared
import Foundation

/// `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's own OAuth token.
public final class ClaudeUsageProvider: UsageProvider {
    public let agent = Agent.claude

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let timeout: TimeInterval = 15

    private let session: URLSession
    private let home: URL
    private let claudeVersion: @Sendable () async -> String
    private let logger = UsageLog.logger("claude")

    public init(
        session: URLSession = .shared,
        home: URL,
        claudeVersion: @escaping @Sendable () async -> String
    ) {
        self.session = session
        self.home = home
        self.claudeVersion = claudeVersion
    }

    public func fetch() async throws(UsageError) -> AgentUsage {
        let now = Date()
        let token: ClaudeCredentials.Token
        switch ClaudeCredentials.load(home: home, now: now) {
        case .success(let value): token = value
        case .failure(let error): throw error
        }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Mandatory: without it the request lands in a punishing rate-limit bucket that
        // returns sticky 429s with no Retry-After (claude-code#31637).
        request.setValue("claude-code/\(await claudeVersion())", forHTTPHeaderField: "User-Agent")

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

    public static func detect() async -> String {
        await Cache.shared.version { await probe() }
    }

    private static func probe() async -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let executable = await ExecutableLocator.find("claude", home: home),
              let output = await ProcessRunner.output(
                  executable: executable,
                  arguments: ["--version"],
                  timeout: .seconds(10)
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
