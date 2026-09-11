import Testing
import Foundation
import SwiftUI
@testable import MusicFeature
import IslandCore
import NowPlayingShared
import NowPlayingClient

@MainActor
final class FakePresenter: IslandPresenting {
    var presented: [Presentation] = []
    var updated: [Presentation] = []
    var dismissed: [PresentationID] = []
    var live: [PresentationID: Presentation] = [:]

    func present(_ p: Presentation) { presented.append(p); live[p.id] = p }
    func update(_ p: Presentation) { updated.append(p); live[p.id] = p }
    func dismiss(_ id: PresentationID) { dismissed.append(id); live.removeValue(forKey: id) }
}

@MainActor
final class ManualClock: IslandClock {
    private struct Entry { let due: Duration; let action: @MainActor () -> Void; let id: Int }
    private var entries: [Entry] = []
    private var nextID = 0
    private(set) var now: Duration = .zero
    /// Wall-clock origin the virtual `now` is measured from.
    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    var currentDate: Date { startDate.addingTimeInterval(now.timeIntervalValue) }
    var pendingCount: Int { entries.count }
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let id = nextID; nextID += 1
        entries.append(Entry(due: now + delay, action: action, id: id))
        return ScheduledToken { [weak self] in self?.entries.removeAll { $0.id == id } }
    }
    func advance(by delta: Duration) {
        let target = now + delta
        while let next = entries.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            entries.removeAll { $0.id == next.id }
            next.action()
        }
        now = target
    }
}

private extension Duration {
    var timeIntervalValue: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

private func snap(_ title: String?, rate: Double = 1, artworkID: String? = "a", artwork: Data? = Data([1]),
                  timestamp: Date = Date()) -> NowPlayingSnapshot {
    NowPlayingSnapshot(title: title, artist: "Artist", album: nil, artworkData: artwork, artworkID: artworkID,
                       duration: 100, elapsed: 5, playbackRate: rate, sourceBundleID: "com.spotify.client", timestamp: timestamp)
}

@MainActor
struct MusicViewModelTests {
    func make() -> (MusicViewModel, FakePresenter, ManualClock, SentCommands) {
        let presenter = FakePresenter()
        let clock = ManualClock()
        let sent = SentCommands()
        let vm = MusicViewModel(presenter: presenter, clock: clock,
                                sendCommand: { await sent.append($0) },
                                viewFactory: .placeholder,
                                now: { MainActor.assumeIsolated { clock.currentDate } })
        return (vm, presenter, clock, sent)
    }

    @Test func firstTrackPresentsBackgroundPeek() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One")))
        #expect(presenter.presented.count == 1)
        #expect(presenter.presented[0].priority == .background)
        #expect(presenter.presented[0].style == .peek)
        #expect(presenter.presented[0].featureID == FeatureID("music"))
    }

    @Test func snapshotWithoutTitleDismisses() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One")))
        let id = presenter.presented[0].id
        vm.handle(.snapshot(snap(nil)))
        #expect(presenter.dismissed == [id])
    }

    @Test func trackChangeWhilePlayingShowsTimedActivityPeek() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One")))
        vm.handle(.snapshot(snap("Two", artworkID: "b")))
        let peeks = presenter.presented.filter { $0.priority == .activity }
        #expect(peeks.count == 1)
        #expect(peeks[0].ttl == MusicViewModel.trackChangePeekDuration)
        #expect(presenter.updated.count == 1)   // background presentation refreshed
    }

    @Test func trackChangeWhilePausedDoesNotPeek() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One", rate: 0)))
        vm.handle(.snapshot(snap("Two", rate: 0, artworkID: "b")))
        #expect(presenter.presented.filter { $0.priority == .activity }.isEmpty)
    }

    @Test func artworkPersistsWhenSnapshotOmitsBytes() {
        let (vm, _, _, _) = make()
        vm.handle(.snapshot(snap("One", artwork: Data([7]))))
        vm.handle(.snapshot(snap("One", artwork: nil)))
        #expect(vm.artwork == Data([7]))
    }

    @Test func newArtworkIDWithoutBytesClearsArtwork() {
        let (vm, _, _, _) = make()
        vm.handle(.snapshot(snap("One", artworkID: "a", artwork: Data([7]))))
        vm.handle(.snapshot(snap("Two", artworkID: "b", artwork: nil)))
        #expect(vm.artwork == nil)
    }

    @Test func longPauseDismissesAndResumeRepresents() {
        let (vm, presenter, clock, _) = make()
        vm.handle(.snapshot(snap("One")))
        let id = presenter.presented[0].id
        vm.handle(.snapshot(snap("One", rate: 0)))
        clock.advance(by: MusicViewModel.pauseDismissDelay - .seconds(1))
        #expect(presenter.dismissed.isEmpty)
        clock.advance(by: .seconds(1))
        #expect(presenter.dismissed == [id])
        vm.handle(.snapshot(snap("One", rate: 1)))
        #expect(presenter.presented.count == 2)
        #expect(presenter.presented[1].id != id)
    }

    @Test func resumeBeforeDelayCancelsDismiss() {
        let (vm, presenter, clock, _) = make()
        vm.handle(.snapshot(snap("One")))
        vm.handle(.snapshot(snap("One", rate: 0)))
        vm.handle(.snapshot(snap("One", rate: 1)))
        clock.advance(by: MusicViewModel.pauseDismissDelay + .seconds(1))
        #expect(presenter.dismissed.isEmpty)
    }

    @Test func unavailableEventDismisses() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One")))
        vm.handle(.unavailable("gone"))
        #expect(presenter.dismissed.count == 1)
    }

    @Test func performForwardsCommands() async {
        let (vm, _, _, sent) = make()
        vm.perform(.next)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await sent.all == [.next])
    }

    @Test func tickingUpdatesElapsedOnlyWhilePlaying() {
        let (vm, _, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.startTicking()
        clock.advance(by: .seconds(3))
        #expect(abs(vm.displayedElapsed - 8) < 0.01)
        vm.stopTicking()
        clock.advance(by: .seconds(5))
        #expect(abs(vm.displayedElapsed - 8) < 0.01)
    }

    @Test func tickingHoldsWhilePaused() {
        let (vm, _, clock, _) = make()
        vm.handle(.snapshot(snap("One", rate: 0, timestamp: clock.currentDate)))
        vm.startTicking()
        clock.advance(by: .seconds(3))
        #expect(abs(vm.displayedElapsed - 5) < 0.01)
    }

    @Test func dismissStopsTicking() {
        let (vm, _, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.startTicking()
        vm.handle(.snapshot(snap(nil, timestamp: clock.currentDate)))
        let frozen = vm.displayedElapsed
        clock.advance(by: .seconds(5))
        #expect(clock.pendingCount == 0)
        #expect(vm.displayedElapsed == frozen)
    }
}

actor SentCommands {
    private(set) var all: [PlaybackCommand] = []
    func append(_ c: PlaybackCommand) { all.append(c) }
}
