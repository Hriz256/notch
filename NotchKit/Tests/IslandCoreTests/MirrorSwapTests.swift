import Testing
@testable import IslandCore

/// `SurfaceController` needs two real windows and a notch screen, so the part of the
/// mirror swap worth checking is pulled out into this value.
@Suite struct MirrorSwapTests {

    /// While a drag is in flight the mirror — which lives in the ordinary user Space,
    /// below the system's drag image — is the one drawing the island.
    @Test func mirroringHidesThePrimaryAndGivesTheMirrorContent() {
        let swap = MirrorSwap.resolve(mirrored: true)
        #expect(swap.primaryAlpha == 0)
        #expect(swap.mirrorAlpha == 1)
        #expect(swap.mirrorHasContent)
    }

    /// Released, the private-Space window draws again and the mirror is emptied, so an
    /// idle mirror renders nothing.
    @Test func releasingRestoresThePrimaryAndEmptiesTheMirror() {
        let swap = MirrorSwap.resolve(mirrored: false)
        #expect(swap.primaryAlpha == 1)
        #expect(swap.mirrorAlpha == 0)
        #expect(!swap.mirrorHasContent)
    }

    /// Exactly one of the two windows is ever visible: the swap can never blank the
    /// island or show it twice.
    @Test func exactlyOneWindowIsVisibleInEitherState() {
        for mirrored in [true, false] {
            let swap = MirrorSwap.resolve(mirrored: mirrored)
            #expect(swap.primaryAlpha + swap.mirrorAlpha == 1)
        }
    }
}
