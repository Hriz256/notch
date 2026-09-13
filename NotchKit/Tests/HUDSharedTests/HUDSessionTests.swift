import Testing
@testable import HUDShared

struct HUDSessionTests {
    private let half = HUDReading(kind: .volume, level: 0.5)
    private let loud = HUDReading(kind: .volume, level: 0.75)
    private let dim = HUDReading(kind: .brightness, level: 0.3)

    @Test func holdIsOneAndAHalfSeconds() {
        #expect(HUDSession.holdDuration == .milliseconds(1500))
    }

    @Test func baselineNeverPresents() {
        var session = HUDSession()
        session.baseline(half)
        #expect(session.current == nil)
        // The same value arriving again is not a change.
        #expect(session.receive(half) == .none)
        #expect(session.current == nil)
    }

    @Test func firstChangePresents() {
        var session = HUDSession()
        session.baseline(half)
        #expect(session.receive(loud) == .present(loud))
        #expect(session.current == loud)
    }

    @Test func changeWithoutABaselinePresents() {
        var session = HUDSession()
        #expect(session.receive(half) == .present(half))
    }

    @Test func sameKindUpdates() {
        var session = HUDSession()
        #expect(session.receive(half) == .present(half))
        #expect(session.receive(loud) == .update(loud))
        #expect(session.receive(loud) == .none)
        #expect(session.current == loud)
    }

    @Test func otherKindReplaces() {
        var session = HUDSession()
        #expect(session.receive(half) == .present(half))
        #expect(session.receive(dim) == .replace(dim))
        #expect(session.current == dim)
    }

    @Test func aReadingEqualToItsOwnBaselineLeavesTheOtherKindUp() {
        var session = HUDSession()
        session.baseline(half)
        #expect(session.receive(dim) == .present(dim))
        // An auto-brightness-style tick of the *volume*'s last known value is not a change,
        // so it must not replace the brightness HUD that is up.
        #expect(session.receive(half) == .none)
        #expect(session.current == dim)
    }

    @Test func baselineForOneKindLeavesTheOtherKindsAlone() {
        var session = HUDSession()
        session.baseline(half)
        session.baseline(dim)
        #expect(session.receive(half) == .none)
        #expect(session.receive(dim) == .none)
        #expect(session.current == nil)
    }

    @Test func muteToggleIsAChangeEachWay() {
        var session = HUDSession()
        session.baseline(half)
        let muted = HUDReading(kind: .volume, level: 0.5, isMuted: true)
        #expect(session.receive(muted) == .present(muted))
        #expect(session.receive(half) == .update(half))
    }

    @Test func expireClearsAndTheNextChangePresentsAfresh() {
        var session = HUDSession()
        #expect(session.receive(half) == .present(half))
        let expired = session.expire()
        #expect(expired)
        #expect(session.current == nil)
        let expiredAgain = session.expire()
        #expect(!expiredAgain)
        // Not a repeat of the value on screen any more — but it *is* the last known value,
        // so it is still not a change.
        #expect(session.receive(half) == .none)
        #expect(session.receive(loud) == .present(loud))
    }
}
