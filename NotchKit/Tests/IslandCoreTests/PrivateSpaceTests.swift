import AppKit
import Testing
@testable import IslandCore

@MainActor
struct PrivateSpaceTests {
    /// Guards the `dlsym` symbol names: if a macOS release renames or drops one of the
    /// SkyLight entry points, `PrivateSpace()` starts returning nil and the island
    /// silently goes back to sliding with Space transitions.
    @Test func resolvesSkyLightSymbols() throws {
        let space = try #require(
            PrivateSpace(),
            """
            SkyLight private space unavailable — either the framework is missing or one of \
            SLSMainConnectionID / SLSSpaceCreate / SLSSpaceSetAbsoluteLevel / SLSShowSpaces / \
            SLSSpaceAddWindowsAndRemoveFromSpaces no longer resolves on this macOS.
            """
        )
        #expect(space.identifier != 0)
        space.destroy()
    }

    /// `release` is the inverse of `adopt`, and the Drop Zones panel calls both on every
    /// drag: the round trip has to be safe to repeat on a live window. Nothing here can
    /// assert *which* Space the WindowServer put the window in — that is not readable
    /// from our side — so this guards the one thing that can break, which is the call
    /// itself (a missing `SLSGetActiveSpace`, an unrealized window, a trap on re-entry).
    @Test func releasingAndReAdoptingAWindowIsSafeToRepeat() throws {
        let space = try #require(PrivateSpace(), "SkyLight private space unavailable on this macOS")
        defer { space.destroy() }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        space.adopt(window)
        space.release(window)
        space.release(window)  // idempotent
        space.adopt(window)

        #expect(space.identifier != 0)
    }

    /// A destroyed space refuses both moves rather than talking to a dead space id.
    @Test func releaseIsANoOpOnceTheSpaceIsDestroyed() throws {
        let space = try #require(PrivateSpace(), "SkyLight private space unavailable on this macOS")
        space.destroy()

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        space.release(window)
        space.adopt(window)
    }
}
