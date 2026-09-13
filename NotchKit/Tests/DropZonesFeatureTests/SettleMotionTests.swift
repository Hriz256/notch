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
        #expect(SettleMotion.response == 0.4)
        #expect(SettleMotion.damping == 0.75)
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

    @Test("The settle window is the view model's own 400 ms, not a second copy of it")
    func theWindowTracksTheViewModel() {
        let delay = DropZonesViewModel.settleDelay.components
        let seconds = Double(delay.seconds) + Double(delay.attoseconds) * 1e-18
        #expect(abs(seconds - SettleMotion.settleWindow) < 1e-9)
    }

    /// Seven boxes at 40 ms would be 240 ms of fan-in, past B9's 0.2 s cap, so the row's
    /// step shortens instead of the row reading as slow.
    @Test("A full row shortens its step to stay inside B9's 0.2 s cap")
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

    @Test("The fan's angles, depth scales and offsets are untouched by the entrance")
    func fanGeometryIsUnchanged() {
        let large = ThumbnailStackTokens.large
        #expect(large.rotation(depth: 0) == 0)
        #expect(large.rotation(depth: 1) == -10)
        #expect(large.rotation(depth: 2) == 10)
        #expect(large.scale(depth: 1) == 0.94)
        #expect(large.scale(depth: 2) == 0.88)
        #expect(ThumbnailStackTokens.depthOffset == 2)
        // The tiles land from above their resting size; the row grows into it.
        #expect(ThumbnailStack.entranceScale == 1.12)
        #expect(StashRowLayout.entranceScale == 0.92)
    }
}
