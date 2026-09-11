import Foundation

/// Parses the `account/rateLimits/read` reply from `codex app-server`.
///
/// The same payload has two spellings: the app-server is camelCase
/// (`usedPercent` / `windowDurationMins` / `resetsAt`) and the rollout JSONL is
/// snake_case (`used_percent` / `window_minutes` / `resets_at`). Both are accepted,
/// as are epoch-second and ISO-8601 reset stamps.
public enum CodexRateLimitParser {
    /// - Returns: `nil` when the JSON carries no rate-limit payload at all.
    public static func parse(_ json: [String: Any], now: Date) -> AgentUsage? {
        let result = UsageJSON.object(json["result"]) ?? json
        guard let limits = UsageJSON.object(UsageJSON.value(result, "rateLimits", "rate_limits"))
                ?? UsageJSON.object(UsageJSON.value(json, "rateLimits", "rate_limits"))
        else { return nil }

        return AgentUsage(
            agent: .codex,
            session: window(UsageJSON.object(limits["primary"])),
            weekly: window(UsageJSON.object(limits["secondary"])),
            sparkline: [],
            fetchedAt: now,
            planLabel: UsageJSON.string(UsageJSON.value(limits, "planType", "plan_type"))
        )
    }

    private static func window(_ object: [String: Any]?) -> UsageWindow? {
        guard let object,
              let percent = UsageJSON.double(UsageJSON.value(object, "usedPercent", "used_percent"))
        else { return nil }
        let resetsAt = UsageJSON.date(UsageJSON.value(object, "resetsAt", "resets_at", "reset_at"))
        return UsageWindow(percent: percent, resetsAt: resetsAt)
    }
}
