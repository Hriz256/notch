import Foundation
import HUDShared
import IslandCore
import SwiftUI
import Testing
@testable import HUDFeature

@MainActor
struct HUDViewModelTests {
    private let half = HUDReading(kind: .volume, level: 0.5)
    private let loud = HUDReading(kind: .volume, level: 0.75)
    private let dim = HUDReading(kind: .brightness, level: 0.3)

    private func make() -> (HUDViewModel, RecordingPresenter, ManualClock) {
        let presenter = RecordingPresenter()
        let clock = ManualClock()
        let factory = HUDViewFactory(
            leading: { _ in AnyView(EmptyView()) },
            trailing: { _ in AnyView(EmptyView()) }
        )
        let model = HUDViewModel(presenter: presenter, clock: clock, viewFactory: factory)
        return (model, presenter, clock)
    }

    @Test func baselineNeverPresents() {
        let (model, presenter, _) = make()
        model.baseline(half)
        model.receive(half)
        #expect(presenter.presented.isEmpty)
        #expect(model.reading == nil)
    }

    @Test func firstChangePresentsATransientAlertPeekWithWideSlots() throws {
        let (model, presenter, _) = make()
        model.receive(half)

        let p = try #require(presenter.presented.first)
        #expect(p.featureID == HUDViewModel.featureID)
        #expect(p.title == "HUD")
        #expect(p.priority == .alert)
        #expect(p.style == .peek)
        #expect(p.ttl == HUDSession.holdDuration)
        #expect(p.expanded == nil)
        #expect(p.showsStackDots == false)
        #expect(p.peekSlotWidth == 96)
        #expect(model.reading == half)
    }

    @Test func sameKindRepresentsUnderTheSameIDAndNeverUpdates() throws {
        let (model, presenter, _) = make()
        model.receive(half)
        model.receive(loud)

        #expect(presenter.presented.count == 2)
        #expect(presenter.presented[0].id == presenter.presented[1].id)
        #expect(presenter.updated.isEmpty)
        #expect(model.reading == loud)
    }

    @Test func otherKindDismissesTheOldAndPresentsAFreshID() throws {
        let (model, presenter, _) = make()
        model.receive(half)
        model.receive(dim)

        let first = try #require(presenter.presented.first)
        #expect(presenter.dismissed == [first.id])
        #expect(presenter.presented.count == 2)
        #expect(presenter.presented[1].id != first.id)
        #expect(model.reading == dim)
    }

    @Test func holdExpiresAfterTheLastChange() throws {
        let (model, presenter, clock) = make()
        model.receive(half)
        clock.advance(by: .milliseconds(1000))
        model.receive(loud)                      // re-arms
        clock.advance(by: .milliseconds(1000))   // 2.0 s since the first, 1.0 s since the last
        #expect(presenter.dismissed.isEmpty)
        #expect(model.reading == loud)

        clock.advance(by: .milliseconds(500))
        let id = try #require(presenter.presented.first?.id)
        #expect(presenter.dismissed == [id])
        // The reading stays put while the presentation fades out, so the bar keeps its level.
        #expect(model.reading == loud)

        // After the hold, the next change is a fresh HUD.
        model.receive(half)
        #expect(presenter.presented.count == 3)
        #expect(presenter.presented[2].id != id)
    }

    @Test func identicalReadingIsIgnored() {
        let (model, presenter, _) = make()
        model.receive(half)
        model.receive(half)
        #expect(presenter.presented.count == 1)
    }

    @Test func stopDismissesAndIgnoresLaterReadings() throws {
        let (model, presenter, clock) = make()
        model.receive(half)
        model.stop()

        let id = try #require(presenter.presented.first?.id)
        #expect(presenter.dismissed == [id])
        #expect(model.reading == nil)
        #expect(clock.pendingCount == 0)

        model.receive(loud)
        #expect(presenter.presented.count == 1)
    }
}
