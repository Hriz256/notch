import CodeAgentShared
import Foundation

/// Cursor's undocumented dashboard usage endpoint, authenticated with the session token
/// Cursor stores in its own VS Code state database.
///
/// Every step here is reverse-engineered and may break without notice, so every failure
/// collapses to one user-facing message rather than a diagnostic cascade.
public final class CursorUsageProvider: UsageProvider {
    public let agent = Agent.cursor

    private static let signInHint = "Sign in to Cursor"
    private static let timeout: TimeInterval = 15

    private let session: URLSession
    private let home: URL
    private let logger = UsageLog.logger("cursor")

    public init(session: URLSession = .shared, home: URL) {
        self.session = session
        self.home = home
    }

    private var databaseURL: URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public func fetch() async throws(UsageError) -> AgentUsage {
        guard let token = await accessToken(), let userID = Self.userID(fromJWT: token) else {
            throw UsageError.unavailable(Self.signInHint)
        }

        var components = URLComponents(string: "https://cursor.com/api/usage")!
        components.queryItems = [URLQueryItem(name: "user", value: userID)]
        guard let url = components.url else { throw UsageError.unavailable(Self.signInHint) }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // `<userId>%3A%3A<token>` — the `::` separator stays percent-encoded inside the value.
        request.setValue(
            "WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
            forHTTPHeaderField: "Cookie"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.debug("cursor usage request failed: \(error.localizedDescription, privacy: .public)")
            throw UsageError.unavailable(Self.signInHint)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UsageError.unavailable(Self.signInHint)
        }
        guard let usage = Self.parse(data, now: Date()) else {
            throw UsageError.unavailable(Self.signInHint)
        }
        return usage
    }

    // MARK: - Token

    /// Read-only shell-out, so a crash mid-read cannot corrupt Cursor's live database.
    private func accessToken() async -> String? {
        let path = databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let output = await ProcessRunner.output(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-readonly", path, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"],
            timeout: .seconds(10)
        )
        let token = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    /// The JWT's `sub` is `auth0|user_0123…`; both the query parameter and the cookie use
    /// the part *after* the pipe. The signature is never checked — this is an id lookup,
    /// not an authorization decision.
    static func userID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let sub = root["sub"] as? String, !sub.isEmpty
        else { return nil }

        let segments = sub.split(separator: "|")
        return segments.count >= 2 ? String(segments[1]) : sub
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var normalized = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    // MARK: - Response

    /// Legacy shape: `{ "gpt-4": { numRequests, maxRequestUsage, … }, "startOfMonth": "…" }`.
    /// Cursor bills monthly requests, so there is no weekly window and no window length
    /// (a calendar month is not a fixed interval, which would make pace meaningless).
    static func parse(_ data: Data, now: Date) -> AgentUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let quota = root["gpt-4"] as? [String: Any],
              let used = (quota["numRequests"] as? NSNumber)?.doubleValue,
              let limit = (quota["maxRequestUsage"] as? NSNumber)?.doubleValue,
              limit > 0
        else { return nil }

        var resetsAt: Date?
        if let startOfMonth = root["startOfMonth"] as? String,
           let start = monthStart(startOfMonth) {
            resetsAt = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: start)
        }

        let percent = min(used / limit * 100, 100)
        return AgentUsage(
            agent: .cursor,
            session: UsageWindow(percent: percent, resetsAt: resetsAt, windowLength: nil),
            weekly: nil,
            sparkline: [],
            fetchedAt: now,
            planLabel: nil
        )
    }

    /// `ISO8601DateFormatter` is not `Sendable`, and this runs once per poll, so the
    /// formatters are built on the spot rather than shared.
    private static func monthStart(_ string: String) -> Date? {
        let candidates: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in candidates {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
