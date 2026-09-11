import Foundation
import AppKit
import os

/// Remembers when each distinct AppleScript error number was last logged, so a permanently
/// failing script (a denied Automation permission, -1743) cannot spam the log on every poll.
final class AppleScriptErrorThrottle: @unchecked Sendable {
    // @unchecked: `lastLogged` is guarded by `lock`.
    private let lock = NSLock()
    private var lastLogged: [Int: Date] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = 60) { self.window = window }

    /// True the first time an error number is seen, and at most once per `window` after that.
    func shouldLog(errorNumber: Int, now: Date = Date()) -> Bool {
        lock.withLock {
            if let last = lastLogged[errorNumber], now.timeIntervalSince(last) < window { return false }
            lastLogged[errorNumber] = now
            return true
        }
    }
}

/// Runs AppleScript off the main thread. Only targets apps that are already running,
/// so a script never launches Spotify or Music by accident.
enum AppleScriptRunner {
    private static let logger = Logger(subsystem: "app.notch", category: "nowplaying.applescript")
    private static let throttle = AppleScriptErrorThrottle()

    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let script = NSAppleScript(source: source) else {
                    log(errorNumber: 0, message: "could not compile script")
                    continuation.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let error {
                    log(errorNumber: error[NSAppleScript.errorNumber] as? Int ?? 0,
                        message: error[NSAppleScript.errorMessage] as? String ?? "unknown error")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result.stringValue)
            }
        }
    }

    /// Throttled so a permanent failure (e.g. -1743, Automation denied) logs at most once a minute.
    private static func log(errorNumber: Int, message: String) {
        guard throttle.shouldLog(errorNumber: errorNumber) else { return }
        logger.error("AppleScript failed (\(errorNumber, privacy: .public)): \(message, privacy: .public)")
    }
}
