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
}
