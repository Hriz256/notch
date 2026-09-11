import Foundation

/// Reads token totals out of Claude Code transcript lines
/// (`~/.claude/projects/**/*.jsonl`) for the 7-day sparkline.
public enum ClaudeUsageLog {
    /// One assistant turn's token cost.
    public struct Entry: Sendable, Equatable {
        /// `"<message.id>:<requestId>"`, or `nil` when either half is missing.
        public var key: String?
        public var tokens: Int
        public var timestamp: Date

        public init(key: String?, tokens: Int, timestamp: Date) {
            self.key = key
            self.tokens = tokens
            self.timestamp = timestamp
        }
    }

    /// - Returns: `nil` unless the line is an `assistant` record carrying `message.usage`
    ///   and a parseable timestamp.
    public static func entry(fromLine line: String) -> Entry? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              UsageJSON.string(root["type"]) == "assistant",
              let message = UsageJSON.object(root["message"]),
              let usage = UsageJSON.object(message["usage"]),
              let timestampString = UsageJSON.string(root["timestamp"]),
              let timestamp = UsageJSON.date(fromISO: timestampString)
        else { return nil }

        let key: String?
        if let messageID = UsageJSON.string(message["id"]),
           let requestID = UsageJSON.string(UsageJSON.value(root, "requestId", "request_id")) {
            key = "\(messageID):\(requestID)"
        } else {
            key = nil
        }

        return Entry(key: key, tokens: tokens(usage: usage), timestamp: timestamp)
    }

    private static func tokens(usage: [String: Any]) -> Int {
        let input = UsageJSON.int(usage["input_tokens"]) ?? 0
        let output = UsageJSON.int(usage["output_tokens"]) ?? 0
        let cacheRead = UsageJSON.int(usage["cache_read_input_tokens"]) ?? 0

        // Prefer the nested ephemeral buckets over the flat field (ccusage does the same).
        let cacheCreation: Int
        if let nested = UsageJSON.object(usage["cache_creation"]) {
            cacheCreation = (UsageJSON.int(nested["ephemeral_5m_input_tokens"]) ?? 0)
                + (UsageJSON.int(nested["ephemeral_1h_input_tokens"]) ?? 0)
        } else {
            cacheCreation = UsageJSON.int(usage["cache_creation_input_tokens"]) ?? 0
        }

        return input + output + cacheCreation + cacheRead
    }

    /// Buckets entries into `days` calendar-day totals ending on the day containing
    /// `endingAt`, oldest first.
    ///
    /// Entries sharing a key are deduplicated last-one-wins; keyless entries all count.
    /// Entries outside the window are dropped. The result always has `days` elements.
    public static func dailyTotals(
        entries: [Entry],
        days: Int,
        endingAt: Date,
        calendar: Calendar
    ) -> [Double] {
        guard days > 0 else { return [] }
        var totals = [Double](repeating: 0, count: days)

        var deduped: [Entry] = []
        var indexByKey: [String: Int] = [:]
        for entry in entries {
            guard let key = entry.key else {
                deduped.append(entry)
                continue
            }
            if let existing = indexByKey[key] {
                deduped[existing] = entry
            } else {
                indexByKey[key] = deduped.count
                deduped.append(entry)
            }
        }

        let endDay = calendar.startOfDay(for: endingAt)
        for entry in deduped {
            let day = calendar.startOfDay(for: entry.timestamp)
            guard let offset = calendar.dateComponents([.day], from: day, to: endDay).day,
                  offset >= 0, offset < days
            else { continue }
            totals[days - 1 - offset] += Double(entry.tokens)
        }
        return totals
    }
}
