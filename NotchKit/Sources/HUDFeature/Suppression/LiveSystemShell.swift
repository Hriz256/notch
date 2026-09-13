import Darwin
import Foundation
import os

/// The real `SystemShell`. `CFPreferences` for the preference (what `defaults write`
/// does), `launchctl kickstart -k` for both restarts, `libproc` to find and stop the helper
/// — no `killall`, no `osascript`.
public final class LiveSystemShell: SystemShell {
    /// Kept as `String`: `CFString` is not `Sendable`, so the bridge happens at the call site.
    private static let controlCenterDomain = "com.apple.controlcenter"
    private static let bannersKey = "EnableSystemBanners"
    private static let osdHelperPath = "/System/Library/CoreServices/OSDUIHelper.app/Contents/MacOS/OSDUIHelper"
    private static let logger = Logger(subsystem: "app.notch", category: "hud.suppressor")
    /// `pbi_status` value for a stopped process (`SSTOP` in `sys/proc.h`).
    private static let stoppedStatus: UInt32 = 4
    /// The helper takes a moment to appear after `kickstart`; `stop` polls for up to this long.
    private static let helperAppearTimeout: TimeInterval = 1.0

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

    public func restartControlCenter() {
        Self.kickstart("com.apple.controlcenter")
    }

    public func kickstartOSDUIHelper() {
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

    private static func kickstart(_ label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
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
