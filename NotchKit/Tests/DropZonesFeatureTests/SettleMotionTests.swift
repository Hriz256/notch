import Foundation
import SwiftUI
import Testing

@testable import DropZonesFeature

/// How dropped tiles arrive. The curve is assertable because `Animation` is `Equatable`;
/// the stagger is assertable because it is arithmetic.
@MainActor
@Suite("Settle motion")
struct SettleMotionTests {

    // MARK: - The curve (audit A8)

    @Test("Tiles settle on a spring rather than parking on an easeOut")
    func curve() {
        // The first tile is handed the bare spring — `.delay(0)` would be a different
        // animation wrapping it, which is how a "no delay" regression would hide.
        #expect(SettleMotion.entrance(index: 0, count: 1, span: 0.1, reduceMotion: false)
            == .spring(response: 0.4, dampingFraction: 0.75))
        #expect(SettleMotion.entrance(index: 1, count: 3, span: 0.1, reduceMotion: false)
            == .spring(response: 0.4, dampingFraction: 0.75).delay(SettleMotion.nominalStagger))
    }

    @Test("Reduce Motion is a plain fade: no spring, no stagger, however many tiles")
    func reducedIsAFadeWithNoStagger() {
        let fade = Animation.easeOut(duration: SettleMotion.fadeDuration)
        for index in 0..<7 {
            #expect(SettleMotion.entrance(
                index: index, count: 7, span: SettleMotion.rowSpan, reduceMotion: true
            ) == fade)
        }
    }

    // MARK: - The stagger (audit B9)

    @Test("The newest tile never waits, and the rest land a step behind each other")
    func delaysAreEvenAndStartAtZero() {
        let span = SettleMotion.settleSpan
        let step = SettleMotion.stagger(count: 3, span: span)
        #expect(SettleMotion.delay(index: 0, count: 3, span: span) == 0)
        #expect(SettleMotion.delay(index: 1, count: 3, span: span) == step)
        #expect(SettleMotion.delay(index: 2, count: 3, span: span) == 2 * step)
    }

    @Test("A lone tile has nothing to stagger against")
    func oneTileHasNoDelay() {
        #expect(SettleMotion.stagger(count: 1, span: 0.2) == 0)
        #expect(SettleMotion.delay(index: 0, count: 1, span: 0.2) == 0)
        #expect(SettleMotion.stagger(count: 0, span: 0.2) == 0)
    }

    @Test("An index past the last tile cannot be handed a delay past the last tile's")
    func indexIsClampedToTheCount() {
        let span = SettleMotion.rowSpan
        #expect(SettleMotion.delay(index: 99, count: 3, span: span)
            == SettleMotion.delay(index: 2, count: 3, span: span))
    }

    /// The fan's three tiles at the nominal 40 ms fit the settle window with room to
    /// spare, so B9's number survives unshortened here.
    @Test("The settle card's stack keeps the nominal 40 ms step")
    func settleCardKeepsTheNominalStep() {
        #expect(SettleMotion.stagger(count: 3, span: SettleMotion.settleSpan)
            == SettleMotion.nominalStagger)
    }

    /// The thing the audit warned about: the stagger must not push the settle past the
    /// 400 ms the island waits before collapsing, which is a constant this work does not
    /// get to move.
    @Test("However many tiles the fan shows, the whole settle is still inside 400 ms")
    func theSettleFitsItsWindow() {
        for count in 1...ThumbnailStack.maximumCards {
            let total = SettleMotion.totalDuration(count: count, span: SettleMotion.settleSpan)
            #expect(total <= SettleMotion.settleWindow + 1e-9,
                    "\(count) tiles take \(total) s of a \(SettleMotion.settleWindow) s window")
        }
    }

    @Test("The settle window is the view model's own timing, not a second copy of it")
    func theWindowTracksTheViewModel() {
        #expect(SettleMotion.settleWindow == DropZonesViewModel.settleDelay.seconds)
        #expect(Duration.milliseconds(400).seconds == 0.4)
        #expect(Duration.milliseconds(250).seconds == 0.25)
        // And the budget keeps a frame back from it, so the last tail is not under the
        // collapse on a slow commit.
        #expect(SettleMotion.settleSpan
            == SettleMotion.settleWindow - SettleMotion.visualRise - SettleMotion.frameSlack)
    }

    /// Seven boxes at 40 ms would put the last one 240 ms out, past B9's 0.2 s cap on when
    /// the last box *starts*, so the row's step shortens instead of a box visibly waiting.
    @Test("A full row shortens its step so the last box starts within 0.2 s")
    func fullRowShortensItsStep() {
        let boxes = StashRowLayout.maximumBoxes
        let step = SettleMotion.stagger(count: boxes, span: SettleMotion.rowSpan)
        #expect(step < SettleMotion.nominalStagger)
        #expect(abs(step - SettleMotion.rowSpan / Double(boxes - 1)) < 1e-9)
        let lastStart = SettleMotion.delay(index: boxes - 1, count: boxes, span: SettleMotion.rowSpan)
        #expect(lastStart <= SettleMotion.rowSpan + 1e-9)
    }

    @Test("A row short enough to afford it keeps the nominal step")
    func shortRowKeepsTheNominalStep() {
        #expect(SettleMotion.stagger(count: 3, span: SettleMotion.rowSpan)
            == SettleMotion.nominalStagger)
    }

    // MARK: - The geometry the stagger must not disturb

    /// The tiles land from *above* their resting size and the row's boxes grow into theirs
    /// — the two entrances are not the same gesture, and swapping them would read as the
    /// row bulging and the drop deflating.
    @Test("A dropped tile arrives from above its resting size, a row's box from below")
    func entranceScalesPointOppositeWays() {
        #expect(ThumbnailStack.entranceScale > 1)
        #expect(StashRowLayout.entranceScale < 1)
    }
}
