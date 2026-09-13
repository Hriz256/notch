import Testing
import CoreGraphics
@testable import IslandCore

/// The island reacts when a card takes it over — but only when nothing else would.
@MainActor
struct IslandArrivalTests {
    private let music = FeatureID("music")
    private let code = FeatureID("code")
    private let hud = FeatureID("hud")

    private func layout(_ size: CGSize, mode: IslandLayout.Mode) -> IslandLayout {
        IslandLayout(mode: mode, size: size, topRadius: 8, bottomRadius: 14)
    }

    private var peek: IslandLayout { layout(CGSize(width: 312, height: 38), mode: .peek) }
    private var widePeek: IslandLayout { layout(CGSize(width: 392, height: 38), mode: .peek) }
    private var collapsed: IslandLayout { layout(CGSize(width: 200, height: 38), mode: .collapsed) }
    private var expanded: IslandLayout { layout(CGSize(width: 390, height: 200), mode: .expanded) }

    private func draw(_ layout: IslandLayout, _ feature: FeatureID) -> IslandDraw {
        IslandDraw(layout: layout, presentationID: PresentationID(), featureID: feature)
    }

    @Test func aSilentArrivalGetsTheBeat() {
        // The case this exists for: a completion alert replacing a peek of the same size.
        // Without it the event the app exists to announce is a crossfade in a box that
        // never twitches.
        #expect(IslandArrival.shouldBeat(from: draw(peek, music), to: draw(peek, code), isReduced: false))
        #expect(IslandArrival.shouldBeat(from: draw(expanded, music), to: draw(expanded, code), isReduced: false))
    }

    @Test func aFeatureReplacingItsOwnCardIsNotAnArrival() {
        // The HUD swapping volume for brightness presents a fresh id at the same 96 pt
        // width: a twitch on every kind change while the user holds a key is noise.
        #expect(!IslandArrival.shouldBeat(from: draw(peek, hud), to: draw(peek, hud), isReduced: false))
    }

    @Test func anArrivalThatAlreadyMovesTheShapeDoesNot() {
        // The geometry spring is already reacting; a second animation on the same value
        // would only fight it.
        #expect(!IslandArrival.shouldBeat(from: draw(peek, music), to: draw(widePeek, code), isReduced: false))
        #expect(!IslandArrival.shouldBeat(from: draw(peek, music), to: draw(expanded, code), isReduced: false))
        #expect(!IslandArrival.shouldBeat(from: draw(expanded, music), to: draw(peek, code), isReduced: false))
    }

    @Test func aRadiusChangeAloneIsStillTheShapeMoving() {
        // The whole layout is compared, not just the size: the radii ride the geometry
        // spring too.
        let rounder = IslandLayout(mode: .peek, size: peek.size, topRadius: 12, bottomRadius: 24)
        #expect(!IslandArrival.shouldBeat(from: draw(peek, music), to: draw(rounder, code), isReduced: false))
    }

    @Test func nothingBeatsWhileTheIslandIsAwayOrJustAppearing() {
        #expect(!IslandArrival.shouldBeat(from: draw(collapsed, music), to: draw(collapsed, code), isReduced: false))
        #expect(!IslandArrival.shouldBeat(from: nil, to: draw(peek, music), isReduced: false))
    }

    @Test func theSameCardRefreshingItselfIsSilent() {
        // A feature re-presenting its card every second must not make the notch twitch
        // every second.
        let card = draw(peek, music)
        #expect(!IslandArrival.shouldBeat(from: card, to: card, isReduced: false))
    }

    @Test func reduceMotionSkipsTheBeatEntirely() {
        #expect(!IslandArrival.shouldBeat(from: draw(peek, music), to: draw(peek, code), isReduced: true))
    }

    @Test func theBeatAimsHighAndIsPulledBackEarly() {
        let beaten = IslandArrival.beat(CGSize(width: 312, height: 38))
        #expect(beaten == CGSize(width: 320, height: 41))
        // A pill twitching vertically reads much louder than one twitching horizontally.
        #expect(IslandArrival.heightBeat < IslandArrival.widthBeat)
        // The aim is never reached: reversing after 90 ms of a 0.32 s spring makes it a
        // pulse of roughly half this, which is the movement we actually want.
        #expect(IslandArrival.widthBeat <= 10)
        #expect(IslandArrival.hold < .seconds(TransitionChoreographer.Spring.arrival.response))
    }

    @Test func theBeatOvershootsOnItsOwnSpring() {
        let c = TransitionChoreographer.standard
        #expect(c.arrival == TransitionChoreographer.Spring.arrival.animation)
        // Loose damping is the point: it has to run out and come back.
        #expect(TransitionChoreographer.Spring.arrival.damping < 0.7)
    }
}

/// What the surface does with a beat it may already be holding.
struct ArrivalBeatChangeTests {
    @Test func aSecondArrivalInsideTheHoldRestartsTheBeat() {
        // Not "joins": the second arrival is its own event, and letting the first beat's
        // sleep end it would truncate it to whatever was left of the 90 ms.
        #expect(IslandArrival.beatChange(arrives: true, layoutChanged: false, isHeld: true) == .start)
        #expect(IslandArrival.beatChange(arrives: true, layoutChanged: false, isHeld: false) == .start)
    }

    @Test func aRealMoveTakesTheFrameAwayFromTheBeat() {
        // An expand arriving inside the hold: the beat is dropped, and dropped without
        // animating, so its loose spring cannot wobble a move the user asked for.
        #expect(IslandArrival.beatChange(arrives: false, layoutChanged: true, isHeld: true) == .cancel)
        // Nothing held, nothing to cancel.
        #expect(IslandArrival.beatChange(arrives: false, layoutChanged: true, isHeld: false) == .none)
    }

    @Test func aMoveOutranksAnArrivalInTheSameDraw() {
        // `shouldBeat` cannot say yes when the layout changed, but the policy is explicit
        // about it rather than relying on that.
        #expect(IslandArrival.beatChange(arrives: true, layoutChanged: true, isHeld: true) == .cancel)
    }

    @Test func aQuietDrawChangesNothing() {
        #expect(IslandArrival.beatChange(arrives: false, layoutChanged: false, isHeld: false) == .none)
        #expect(IslandArrival.beatChange(arrives: false, layoutChanged: false, isHeld: true) == .none)
    }
}
