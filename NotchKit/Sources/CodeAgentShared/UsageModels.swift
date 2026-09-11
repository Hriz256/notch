import Foundation

/// One rate-limit window: how much of it is used, and when it rolls over.
public struct UsageWindow: Codable, Sendable, Equatable {
    /// 0…100.
    public var percent: Double
    /// Absent when the provider does not report a reset time.
    public var resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// A normalized usage snapshot for one agent.
public struct AgentUsage: Codable, Sendable, Equatable {
    public var agent: Agent
    /// Claude `five_hour` / `limits[session]`; Codex `primary`.
    public var session: UsageWindow?
    /// Claude `seven_day` / `limits[weekly_all]`; Codex `secondary`.
    public var weekly: UsageWindow?
    /// Daily token totals, oldest first; empty when unavailable.
    public var sparkline: [Double]
    public var fetchedAt: Date
    /// "Max", "Pro", "free"… when the provider reports one.
    public var planLabel: String?

    public init(
        agent: Agent,
        session: UsageWindow?,
        weekly: UsageWindow?,
        sparkline: [Double],
        fetchedAt: Date,
        planLabel: String?
    ) {
        self.agent = agent
        self.session = session
        self.weekly = weekly
        self.sparkline = sparkline
        self.fetchedAt = fetchedAt
        self.planLabel = planLabel
    }
}

/// Why a usage fetch could not produce a snapshot.
public enum UsageError: Error, Equatable, Sendable {
    case notSignedIn
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case unavailable(String)
}

/// Whether the current burn rate fits the remaining window.
public enum Pace: Sendable, Equatable {
    case good
    case slowDown
}

public enum PaceCalculator {
    /// Tolerance, in percentage points, before usage counts as running hot.
    private static let tolerance: Double = 10

    /// `used% > elapsed% of the window + 10` → `.slowDown`, otherwise `.good`.
    ///
    /// - Parameter windowLength: 5 h for the session window, 7 d for the weekly one.
    /// - Returns: `nil` when the window has no reset time (elapsed fraction is unknowable).
    public static func pace(
        percent: Double,
        resetsAt: Date?,
        windowLength: TimeInterval,
        now: Date
    ) -> Pace? {
        guard let resetsAt, windowLength > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now) / windowLength
        let elapsedFraction = min(max(1 - remaining, 0), 1)
        return percent > elapsedFraction * 100 + tolerance ? .slowDown : .good
    }
}

public enum ResetFormatter {
    /// "6d 13h" / "4h 18m" / "12m", and "now" once the window has rolled over.
    public static func string(until: Date, now: Date) -> String {
        let interval = until.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        guard hours >= 1 else { return "\(totalMinutes)m" }
        guard hours >= 24 else { return "\(hours)h \(totalMinutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}

// MARK: - Shared permissive decoding helpers

enum UsageJSON {
    /// Reset stamps arrive as ISO-8601 (with or without fractional seconds) or as epoch seconds.
    static func date(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber where !(number is NSNull):
            let seconds = number.doubleValue
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        case let string as String:
            return date(fromISO: string)
        default:
            return nil
        }
    }

    static func date(fromISO string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // Fractional seconds with more than three digits: trim to milliseconds and retry.
        if let dot = string.firstIndex(of: "."),
           let end = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = string[string.index(after: dot)..<end]
            if digits.count > 3 {
                let trimmed = string[..<dot]
                    + "."
                    + digits.prefix(3)
                    + string[end...]
                return fractional.date(from: String(trimmed))
            }
        }
        return nil
    }

    /// A JSON number that may be an `Int`, a `Double`, or absent/null.
    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !(number is NSNull) else { return nil }
        // `Bool` bridges to NSNumber too; a boolean percentage is never meaningful.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.doubleValue
    }

    static func int(_ value: Any?) -> Int? {
        double(value).map(Int.init)
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// First non-nil value among `keys`.
    static func value(_ dictionary: [String: Any], _ keys: String...) -> Any? {
        for key in keys {
            if let value = dictionary[key], !(value is NSNull) { return value }
        }
        return nil
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}
