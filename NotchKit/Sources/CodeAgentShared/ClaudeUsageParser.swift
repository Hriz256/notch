import Foundation

/// Parses `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Every field in the response is optional, so any window that lacks a percentage
/// is reported as `nil` rather than as zero. When the newer `limits[]` array carries
/// a `session` / `weekly_all` entry it supersedes the flat `five_hour` / `seven_day`
/// keys; otherwise the flat keys are used.
public enum ClaudeUsageParser {
    /// Claude's windows are fixed by the plan, and the response never states their length.
    static let sessionWindowLength: TimeInterval = 5 * 60 * 60
    static let weeklyWindowLength: TimeInterval = 7 * 24 * 60 * 60

    public static func parse(_ data: Data, now: Date) throws -> AgentUsage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.unavailable("Unrecognized usage response")
        }

        let limits = (root["limits"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        let session = window(limits: limits, kind: "session", length: sessionWindowLength)
            ?? window(UsageJSON.object(root["five_hour"]), length: sessionWindowLength)
        let weekly = window(limits: limits, kind: "weekly_all", length: weeklyWindowLength)
            ?? window(UsageJSON.object(root["seven_day"]), length: weeklyWindowLength)

        return AgentUsage(
            agent: .claude,
            session: session,
            weekly: weekly,
            sparkline: [],
            fetchedAt: now,
            planLabel: UsageJSON.string(root["plan"]) ?? UsageJSON.string(root["plan_type"])
        )
    }

    /// A `limits[]` entry: `{ "kind": …, "percent": …, "resets_at": … }`.
    private static func window(limits: [[String: Any]], kind: String, length: TimeInterval) -> UsageWindow? {
        guard let entry = limits.first(where: { UsageJSON.string($0["kind"]) == kind }) else { return nil }
        guard let percent = UsageJSON.double(UsageJSON.value(entry, "percent", "utilization")) else { return nil }
        return UsageWindow(
            percent: percent,
            resetsAt: UsageJSON.date(UsageJSON.value(entry, "resets_at", "resetsAt")),
            windowLength: length
        )
    }

    /// A flat window: `{ "utilization": …, "resets_at": … }` (status-line spelling
    /// `used_percentage` is accepted too).
    private static func window(_ object: [String: Any]?, length: TimeInterval) -> UsageWindow? {
        guard let object,
              let percent = UsageJSON.double(UsageJSON.value(object, "utilization", "used_percentage", "percent"))
        else { return nil }
        return UsageWindow(
            percent: percent,
            resetsAt: UsageJSON.date(UsageJSON.value(object, "resets_at", "resetsAt")),
            windowLength: length
        )
    }
}
