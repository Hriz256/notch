import Darwin
import Foundation
import os

/// The real `SystemShell`. `CFPreferences` for the preference (what `defaults write`
/// does), signals we send ourselves for both restarts (`SIGTERM` to Control Center, which
/// launchd brings back; `SIGKILL` to the helper, then `launchctl kickstart` *without* `-k`
/// so a fresh one is running), `libproc` to find and stop the helper — no `killall`, no
/// `osascript`. `-k` is not an option here: SIP refuses it for both system agents (exit 150,
/// "Operation not permitted while System Integrity Protection is engaged"), while signalling
/// the processes is allowed because they run as the user.
public final class LiveSystemShell: SystemShell {
    /// Kept as `String`: `CFString` is not `Sendable`, so the bridge happens at the call site.
    private static let controlCenterDomain = "com.apple.controlcenter"
    private static let bannersKey = "EnableSystemBanners"
    private static let osdHelperPath = "/System/Library/CoreServices/OSDUIHelper.app/Contents/MacOS/OSDUIHelper"
    private static let controlCenterPath = "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
    private static let logger = Logger(subsystem: "app.notch", category: "hud.suppressor")
    /// `pbi_status` value for a stopped process (`SSTOP` in `sys/proc.h`).
    private static let stoppedStatus: UInt32 = 4
    /// The helper takes a moment to appear after `kickstart`; `stop` polls for up to this long.
    private static let helperAppearTimeout: TimeInterval = 1.0
    /// A signalled process takes a moment to go; the restarts poll for up to this long.
    private static let processExitTimeout: TimeInterval = 1.0

    public init() {}

    public func bannersPreference() -> Bool? {
        let value = CFPreferencesCopyAppValue(Self.bannersKey as CFString, Self.controlCenterDomain as CFString)
        guard let value else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    public func setBannersPreference(_ value: Bool?) {
        let plist: CFPropertyList? = value.map { $0 ? kCFBooleanTrue! : kCFBooleanFalse! }
        CFPreferencesSetAppValue(Self.bannersKey as CFString, plist, Self.controlCenterDomain as CFString)
        CFPreferencesAppSynchronize(Self.controlCenterDomain as CFString)
    }

    /// `SIGTERM` to the running Control Center; launchd brings it straight back, and it
    /// re-reads `EnableSystemBanners` on the way up. No `launchctl` here at all: SIP refuses
    /// `kickstart -k` for this agent.
    ///
    /// - Returns: `false` when there was no process to signal or the signal was refused —
    ///   Control Center is then *not* known to be running the wanted way.
    public func restartControlCenter() -> Bool {
        guard let pid = Self.pid(ofExecutable: Self.controlCenterPath) else {
            Self.logger.error("no ControlCenter process to restart")
            return false
        }
        guard kill(pid, SIGTERM) == 0 else {
            Self.logger.error("SIGTERM to ControlCenter failed: errno \(errno, privacy: .public)")
            return false
        }
        Self.waitForExit(of: pid)
        return true
    }

    /// A fresh, running helper: `SIGKILL` the old one (a `SIGSTOP`ped process never handles
    /// `SIGTERM`, `SIGKILL` lands on it anyway), then `launchctl kickstart` — without `-k`,
    /// which starts the service if it is not running and is a no-op if it is.
    public func kickstartOSDUIHelper() {
        if let pid = Self.pid(ofExecutable: Self.osdHelperPath) {
            kill(pid, SIGKILL)
            Self.waitForExit(of: pid)
        }
        Self.kickstart("com.apple.OSDUIHelper")
    }

    public func stopOSDUIHelper() -> Bool {
        let deadline = Date().addingTimeInterval(Self.helperAppearTimeout)
        repeat {
            if let pid = Self.pid(ofExecutable: Self.osdHelperPath) {
                return kill(pid, SIGSTOP) == 0
            }
            usleep(50_000)
        } while Date() < deadline
        return false
    }

    public func isOSDUIHelperStopped() -> Bool {
        guard let pid = Self.pid(ofExecutable: Self.osdHelperPath) else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == Self.stoppedStatus
    }

    // MARK: - Private

    /// Blocks until `pid` is gone, or for `processExitTimeout` at the most. Best effort: the
    /// caller's next step works either way.
    private static func waitForExit(of pid: pid_t) {
        let deadline = Date().addingTimeInterval(processExitTimeout)
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        while Date() < deadline {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) <= 0 { return }
            usleep(50_000)
        }
    }

    /// The `launchctl` arguments for `label` — deliberately no `-k`: SIP refuses to kill a
    /// system agent for us (exit 150), and plain `kickstart` starts the service if it is not
    /// running and does nothing if it is, which is all we need after our own `SIGKILL`.
    static func launchctlArguments(for label: String) -> [String] {
        ["kickstart", "gui/\(getuid())/\(label)"]
    }

    private static func kickstart(_ label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = launchctlArguments(for: label)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logger.error("launchctl kickstart \(label, privacy: .public) exited \(process.terminationStatus, privacy: .public)")
            }
        } catch {
            logger.error("launchctl could not run: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The pid of the running process whose executable is `path`, if any.
    private static func pid(ofExecutable path: String) -> pid_t? {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 16)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            if String(decoding: buffer[..<Int(length)], as: UTF8.self) == path { return pid }
        }
        return nil
    }
}
