import Testing
import CoreGraphics
@testable import IslandCore

/// The island reacts when a card takes it over — but only when nothing else would.
struct IslandArrivalTests {
    private func layout(_ size: CGSize, mode: IslandLayout.Mode) -> IslandLayout {
        IslandLayout(mode: mode, size: size, topRadius: 8, bottomRadius: 14)
    }

    private var peek: IslandLayout { layout(CGSize(width: 312, height: 38), mode: .peek) }
    private var widePeek: IslandLayout { layout(CGSize(width: 392, height: 38), mode: .peek) }
    private var collapsed: IslandLayout { layout(CGSize(width: 200, height: 38), mode: .collapsed) }
    private var expanded: IslandLayout { layout(CGSize(width: 390, height: 200), mode: .expanded) }

    @Test func aSilentArrivalGetsTheBeat() {
        // The case this exists for: a completion alert replacing a peek of the same size.
        // Without it the event the app exists to announce is a crossfade in a box that
        // never twitches.
        #expect(IslandArrival.shouldBeat(from: peek, to: peek, presentationChanged: true, isReduced: false))
        #expect(IslandArrival.shouldBeat(from: expanded, to: expanded, presentationChanged: true, isReduced: false))
    }

    @Test func anArrivalThatAlreadyMovesTheShapeDoesNot() {
        // The geometry spring is already reacting; a second animation on the same value
        // would only fight it.
        #expect(!IslandArrival.shouldBeat(from: peek, to: widePeek, presentationChanged: true, isReduced: false))
        #expect(!IslandArrival.shouldBeat(from: peek, to: expanded, presentationChanged: true, isReduced: false))
        #expect(!IslandArrival.shouldBeat(from: expanded, to: peek, presentationChanged: true, isReduced: false))
    }

    @Test func nothingBeatsWhileTheIslandIsAwayOrJustAppearing() {
        #expect(!IslandArrival.shouldBeat(from: collapsed, to: collapsed, presentationChanged: true, isReduced: false))
        #expect(!IslandArrival.shouldBeat(from: nil, to: peek, presentationChanged: true, isReduced: false))
    }

    @Test func theSameCardRefreshingItselfIsSilent() {
        // A feature re-presenting its card every second must not make the notch twitch
        // every second.
        #expect(!IslandArrival.shouldBeat(from: peek, to: peek, presentationChanged: false, isReduced: false))
    }

    @Test func reduceMotionSkipsTheBeatEntirely() {
        #expect(!IslandArrival.shouldBeat(from: peek, to: peek, presentationChanged: true, isReduced: true))
    }

    @Test func theBeatIsSmallAndSameShaped() {
        let beaten = IslandArrival.beat(CGSize(width: 312, height: 38))
        #expect(beaten == CGSize(width: 320, height: 41))
        // A pill twitching vertically reads much louder than one twitching horizontally.
        #expect(IslandArrival.heightBeat < IslandArrival.widthBeat)
        // Small enough to read as the island reacting rather than resizing.
        #expect(IslandArrival.widthBeat <= 10)
        #expect(IslandArrival.hold <= .milliseconds(120))
    }

    @Test func theBeatOvershootsOnItsOwnSpring() {
        let c = TransitionChoreographer.standard
        #expect(c.arrival == TransitionChoreographer.Spring.arrival.animation)
        // Loose damping is the point: it has to run past the target and come back.
        #expect(TransitionChoreographer.Spring.arrival.damping < 0.7)
    }
}
