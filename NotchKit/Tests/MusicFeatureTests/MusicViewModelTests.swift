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
                  elapsed: TimeInterval? = 5, timestamp: Date = Date()) -> NowPlayingSnapshot {
    NowPlayingSnapshot(title: title, artist: "Artist", album: nil, artworkData: artwork, artworkID: artworkID,
                       duration: 100, elapsed: elapsed, playbackRate: rate, sourceBundleID: "com.spotify.client", timestamp: timestamp)
}

@MainActor
struct MusicViewModelTests {
    func make(trackChangePeekEnabled: Bool = true) -> (MusicViewModel, FakePresenter, ManualClock, SentCommands) {
        let presenter = FakePresenter()
        let clock = ManualClock()
        let sent = SentCommands()
        let vm = MusicViewModel(presenter: presenter, clock: clock,
                                sendCommand: { await sent.append($0) },
                                viewFactory: .placeholder,
                                now: { MainActor.assumeIsolated { clock.currentDate } },
                                isTrackChangePeekEnabled: { trackChangePeekEnabled })
        return (vm, presenter, clock, sent)
    }

    @Test func firstTrackPresentsBackgroundPeek() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One")))
        #expect(presenter.presented.count == 1)
        #expect(presenter.presented[0].priority == .background)
        #expect(presenter.presented[0].style == .peek)
        #expect(presenter.presented[0].featureID == FeatureID("music"))
        // Menus name the card by its title, not the feature id.
        #expect(presenter.presented[0].title == "Music")
        #expect(presenter.presented[0].displayTitle == "Music")
    }

    @Test func snapshotWithoutTitleDismisses() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One")))
        let id = presenter.presented[0].id
        vm.handle(.snapshot(snap(nil)))
        #expect(presenter.dismissed == [id])
    }

    @Test func trackChangeUpdatesInPlaceAndFlagsBanner() {
        let (vm, presenter, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        #expect(presenter.presented.count == 1)

        vm.handle(.snapshot(snap("Two", artworkID: "b", timestamp: clock.currentDate)))
        // The island must never be re-presented on a track change: a second presentation swaps
        // the whole panel (new `Presentation` id → new view identity) and reads as a flicker.
        #expect(presenter.presented.count == 1)
        #expect(presenter.updated.count == 1)
        #expect(presenter.updated[0].id == presenter.presented[0].id)
        #expect(vm.isShowingTrackChange)

        clock.advance(by: MusicViewModel.trackChangePeekDuration)
        #expect(vm.isShowingTrackChange == false)
        #expect(presenter.presented.count == 1)
    }

    @Test func consecutiveTrackChangesReArmTheBanner() {
        let (vm, _, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.handle(.snapshot(snap("Two", artworkID: "b", timestamp: clock.currentDate)))
        clock.advance(by: .seconds(2))
        vm.handle(.snapshot(snap("Three", artworkID: "c", timestamp: clock.currentDate)))
        clock.advance(by: .seconds(1))
        #expect(vm.isShowingTrackChange)        // the first timer must not cut the second peek
        clock.advance(by: .seconds(2))
        #expect(vm.isShowingTrackChange == false)
    }

    @Test func trackChangePeekDisabledByPreference() {
        let (vm, presenter, _, _) = make(trackChangePeekEnabled: false)
        vm.handle(.snapshot(snap("One")))
        vm.handle(.snapshot(snap("Two", artworkID: "b")))
        #expect(vm.isShowingTrackChange == false)
        #expect(presenter.presented.count == 1)
        #expect(presenter.updated.count == 1)   // background still refreshed
    }

    @Test func trackChangeWhilePausedDoesNotPeek() {
        let (vm, presenter, _, _) = make()
        vm.handle(.snapshot(snap("One", rate: 0)))
        vm.handle(.snapshot(snap("Two", rate: 0, artworkID: "b")))
        #expect(vm.isShowingTrackChange == false)
        #expect(presenter.presented.count == 1)
    }

    /// MediaRemote replays the outgoing track for a moment after a skip. The data must stay
    /// truthful, but the revert must not re-trigger the banner (that is the visible flicker).
    @Test func revertWithinBurstDoesNotReflag() {
        let (vm, presenter, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.handle(.snapshot(snap("Two", artworkID: "b", timestamp: clock.currentDate)))
        #expect(vm.isShowingTrackChange)

        // Burst echo: back to "One", then "Two" again, both inside the burst window.
        clock.advance(by: .seconds(0.3))
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        #expect(vm.snapshot?.title == "One")     // the data stays truthful
        clock.advance(by: .seconds(0.3))
        vm.handle(.snapshot(snap("Two", artworkID: "b", timestamp: clock.currentDate)))
        #expect(vm.snapshot?.title == "Two")
        #expect(presenter.presented.count == 1)

        // The echoes must not have re-armed the banner: it still expires on the original timer.
        clock.advance(by: MusicViewModel.trackChangePeekDuration - .seconds(0.7))
        #expect(vm.isShowingTrackChange)
        clock.advance(by: .seconds(0.2))
        #expect(vm.isShowingTrackChange == false)
    }

    @Test func revertAfterBurstWindowFlagsAgain() {
        let (vm, _, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.handle(.snapshot(snap("Two", artworkID: "b", timestamp: clock.currentDate)))
        clock.advance(by: MusicViewModel.trackChangePeekDuration)
        // A deliberate "previous track" press long after the skip is a real track change.
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        #expect(vm.isShowingTrackChange)
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

    @Test func togglePlayPauseIsOptimistic() {
        let (vm, presenter, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.startTicking()
        let updatesBefore = presenter.updated.count

        vm.perform(.togglePlayPause)
        #expect(vm.isPlaying == false)
        #expect(presenter.updated.count == updatesBefore + 1)   // compact visualizer refreshed
        let frozen = vm.displayedElapsed
        clock.advance(by: .seconds(3))
        #expect(abs(vm.displayedElapsed - frozen) < 0.01)

        vm.perform(.togglePlayPause)
        #expect(vm.isPlaying)
        clock.advance(by: .seconds(2))
        #expect(abs(vm.displayedElapsed - (frozen + 2)) < 0.01)
    }

    @Test func optimisticToggleDoesNotPeek() {
        let (vm, presenter, clock, _) = make()
        vm.handle(.snapshot(snap("One", rate: 0, timestamp: clock.currentDate)))
        vm.perform(.togglePlayPause)
        #expect(vm.isPlaying)
        #expect(presenter.presented.filter { $0.priority == .activity }.isEmpty)
    }

    @Test func realSnapshotOverridesOptimisticState() {
        let (vm, _, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.perform(.togglePlayPause)
        #expect(vm.isPlaying == false)
        vm.handle(.snapshot(snap("One", rate: 1, timestamp: clock.currentDate)))
        #expect(vm.isPlaying)
    }

    @Test func seekRebasesProjection() {
        let (vm, _, clock, _) = make()
        vm.handle(.snapshot(snap("One", timestamp: clock.currentDate)))
        vm.startTicking()
        vm.perform(.seek(50))
        #expect(abs(vm.displayedElapsed - 50) < 0.01)
        clock.advance(by: .seconds(2))
        #expect(abs(vm.displayedElapsed - 52) < 0.01)
    }

    /// Spotify frequently leaves `ElapsedTime`/`Timestamp` describing a moment *before* the pause,
    /// so the paused snapshot says "0:45 at t0" for a track that had been projected to 1:00. That
    /// pair must not rewind the display.
    @Test func stalePausedSnapshotDoesNotRollBackElapsed() {
        let (vm, _, clock, _) = make()
        let t0 = clock.currentDate
        vm.handle(.snapshot(snap("One", elapsed: 45, timestamp: t0)))
        vm.startTicking()
        clock.advance(by: .seconds(15))
        #expect(abs(vm.displayedElapsed - 60) < 0.01)

        vm.perform(.pause)                       // optimistic pause at t0 + 15, frozen at 60
        #expect(vm.isPlaying == false)

        // The real snapshot echoes the pause but carries the pre-pause pair.
        vm.handle(.snapshot(snap("One", rate: 0, elapsed: 45, timestamp: t0)))
        #expect(abs(vm.displayedElapsed - 60) < 0.01)
        clock.advance(by: .seconds(5))
        #expect(abs(vm.displayedElapsed - 60) < 0.01)
    }

    /// The counterpart: a pair stamped after our base is a genuine update from the source.
    @Test func freshPausedSnapshotIsTrusted() {
        let (vm, _, clock, _) = make()
        let t0 = clock.currentDate
        vm.handle(.snapshot(snap("One", elapsed: 45, timestamp: t0)))
        vm.startTicking()
        clock.advance(by: .seconds(15))
        vm.perform(.pause)

        vm.handle(.snapshot(snap("One", rate: 0, elapsed: 58, timestamp: t0.addingTimeInterval(15.5))))
        #expect(abs(vm.displayedElapsed - 58) < 0.01)
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
