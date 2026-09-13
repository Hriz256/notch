import Foundation
import Testing
@testable import HUDFeature

/// Pure checks on the one piece of `LiveSystemShell` that can be inspected without touching
/// the system. Nothing here runs `launchctl` or signals a process — `LiveSystemShell` itself
/// is compile-only and is never executed by a test.
struct LiveSystemShellTests {
    @Test func launchctlArgumentsTargetTheUsersGUIDomain() {
        let arguments = LiveSystemShell.launchctlArguments(for: "com.apple.OSDUIHelper")
        #expect(arguments == ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"])
    }

    /// SIP refuses `kickstart -k` for system agents (exit 150), so the flag must never
    /// come back: we kill the helper ourselves and only ask launchctl to start it.
    @Test func launchctlArgumentsNeverPassTheKillFlag() {
        #expect(!LiveSystemShell.launchctlArguments(for: "com.apple.OSDUIHelper").contains("-k"))
    }
}
