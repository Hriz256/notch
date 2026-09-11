import Foundation
import AppKit

/// Runs AppleScript off the main thread. Only targets apps that are already running,
/// so a script never launches Spotify or Music by accident.
enum AppleScriptRunner {
    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result?.stringValue : nil)
            }
        }
    }
}
