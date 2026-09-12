import Foundation
import SwiftUI
import Observation
import IslandCore
import NowPlayingShared
import NowPlayingClient

/// Builds the island views for the music feature. Injected so the view model is testable
/// without SwiftUI rendering.
@MainActor
public struct MusicViewFactory {
    public var leading: (MusicViewModel) -> AnyView
    public var trailing: (MusicViewModel) -> AnyView
    public var expanded: (MusicViewModel) -> AnyView

    public init(leading: @escaping (MusicViewModel) -> AnyView,
                trailing: @escaping (MusicViewModel) -> AnyView,
                expanded: @escaping (MusicViewModel) -> AnyView) {
        self.leading = leading
        self.trailing = trailing
        self.expanded = expanded
    }

    public static let placeholder = MusicViewFactory(
        leading: { _ in AnyView(EmptyView()) },
        trailing: { _ in AnyView(EmptyView()) },
        expanded: { _ in AnyView(EmptyView()) }
    )
}

/// Turns now-playing events into island presentations and drives the progress display.
@MainActor
@Observable
public final class MusicViewModel {
    public static let featureID = FeatureID("music")
    /// What this feature's cards are called in menus.
    public static let displayTitle = "Music"
    public static let pauseDismissDelay: Duration = .seconds(600)
    public static let trackChangePeekDuration: Duration = .seconds(2.5)
    public static let expandedSize = CGSize(width: 380, height: 160)
    /// UserDefaults key backing the "Track change peek" setting (absent means on).
    public nonisolated static let trackChangePeekDefaultsKey = "music.trackChangePeek"

    /// MediaRemote replays the outgoing track for a moment after a skip. A revert to the
    /// immediately previous track inside this window is treated as part of that burst: the
    /// snapshot is still applied, but it does not re-trigger the track-change banner.
    static let trackChangeBurstWindow: TimeInterval = 1.5

    public private(set) var snapshot: NowPlayingSnapshot?
    public private(set) var artwork: Data?
    public private(set) var displayedElapsed: TimeInterval = 0
    /// True for `trackChangePeekDuration` after a track changes while playing. Views read this
    /// to surface the new track; the island itself is never re-presented, so nothing flickers.
    public private(set) var isShowingTrackChange = false

    public var isPlaying: Bool { snapshot?.isPlaying ?? false }
    public var duration: TimeInterval { snapshot?.duration ?? 0 }

    /// The island this feature presents on. Exposed read-only so the feature's context
    /// menu can embed `CardsMenuSection`, which needs the presenter to list the cards.
    @ObservationIgnored public let islandPresenter: any IslandPresenting
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private let sendCommand: @Sendable (PlaybackCommand) async -> Void
    @ObservationIgnored private let viewFactory: MusicViewFactory
    /// Wall-clock source, injected so tests can drive progress projection deterministically.
    @ObservationIgnored private let now: @Sendable () -> Date
    /// User preference (`music.trackChangePeek`, default on) gating the track-change peek.
    @ObservationIgnored private let isTrackChangePeekEnabled: @Sendable () -> Bool
    @ObservationIgnored private var backgroundID: PresentationID?
    @ObservationIgnored private var pauseToken: ScheduledToken?
    @ObservationIgnored private var tickToken: ScheduledToken?
    @ObservationIgnored private var trackChangeToken: ScheduledToken?
    /// Identity of the track that was playing *before* the current one, plus when the swap
    /// happened — together they recognise MediaRemote's old/new burst after a skip.
    @ObservationIgnored private var previousTrack: TrackIdentity?
    @ObservationIgnored private var lastTrackChangeAt: Date?

    /// The fields that make a snapshot a different *track* (as opposed to a progress update).
    private struct TrackIdentity: Equatable {
        let title: String?
        let artist: String?
        let artworkID: String?

        init(_ s: NowPlayingSnapshot) {
            title = s.title
            artist = s.artist
            artworkID = s.artworkID
        }
    }

    public init(presenter: any IslandPresenting,
                clock: any IslandClock,
                sendCommand: @escaping @Sendable (PlaybackCommand) async -> Void,
                viewFactory: MusicViewFactory,
                now: @escaping @Sendable () -> Date = { Date() },
                isTrackChangePeekEnabled: @escaping @Sendable () -> Bool = {
                    UserDefaults.standard.object(forKey: MusicViewModel.trackChangePeekDefaultsKey) == nil
                        ? true
                        : UserDefaults.standard.bool(forKey: MusicViewModel.trackChangePeekDefaultsKey)
                }) {
        self.islandPresenter = presenter
        self.clock = clock
        self.sendCommand = sendCommand
        self.viewFactory = viewFactory
        self.now = now
        self.isTrackChangePeekEnabled = isTrackChangePeekEnabled
    }

    // MARK: Events

    public func handle(_ event: NowPlayingEvent) {
        switch event {
        case .unavailable:
            dismissBackground()
        case .snapshot(let new):
            apply(new)
        }
    }

    private func apply(_ new: NowPlayingSnapshot, isOptimistic: Bool = false) {
        var new = new
        if !isOptimistic { freezePositionIfPairIsStale(&new) }
        let old = snapshot
        mergeArtwork(from: new)
        snapshot = new
        displayedElapsed = PlaybackProgressTracker.elapsed(for: new, at: now()) ?? 0

        guard new.hasTrack else {
            dismissBackground()
            return
        }

        let identity = TrackIdentity(new)
        let trackChanged = old.map { TrackIdentity($0) != identity } ?? false

        // A track change keeps the *same* presentation and only refreshes its content. Presenting
        // a second presentation would give the panel a new view identity and blink it away and
        // back — twice, once when the peek appears and once when it expires.
        if let backgroundID {
            islandPresenter.update(makeBackgroundPresentation(id: backgroundID))
        } else {
            let id = PresentationID()
            backgroundID = id
            islandPresenter.present(makeBackgroundPresentation(id: id))
        }

        if trackChanged {
            let isBurstEcho = previousTrack == identity
                && lastTrackChangeAt.map { now().timeIntervalSince($0) <= Self.trackChangeBurstWindow } ?? false
            previousTrack = old.map(TrackIdentity.init)
            lastTrackChangeAt = now()
            if !isBurstEcho, new.isPlaying, isTrackChangePeekEnabled() {
                showTrackChange()
            }
        }

        if new.isPlaying {
            pauseToken?.cancel()
            pauseToken = nil
        } else if pauseToken == nil {
            pauseToken = clock.schedule(after: Self.pauseDismissDelay) { [weak self] in
                self?.dismissBackground()
            }
        }
    }

    /// Defensive mirror of the helper's rule, for sources whose `elapsed`/`timestamp` pair still
    /// describes a moment before the pause (Spotify does not always refresh it). Such a pair
    /// carries rate 0 and a timestamp older than the base we are already projecting from, so
    /// honouring it would rewind the display — a track paused at 1:00 snapping back to 0:45.
    /// The position on screen is kept instead. A pair stamped *after* our base is a genuine
    /// update and is trusted; a track change and a playing snapshot are never touched.
    private func freezePositionIfPairIsStale(_ new: inout NowPlayingSnapshot) {
        guard let current = snapshot,
              !new.isPlaying,
              new.elapsed != nil,
              TrackIdentity(current) == TrackIdentity(new),
              new.timestamp < current.timestamp
        else { return }
        new.elapsed = PlaybackProgressTracker.elapsed(for: current, at: now()) ?? displayedElapsed
        new.timestamp = now()
    }

    private func mergeArtwork(from new: NowPlayingSnapshot) {
        if let data = new.artworkData {
            artwork = data
        } else if new.artworkID != snapshot?.artworkID {
            artwork = nil
        }
    }

    /// Tears the feature down to idle: no presentation, no pause timer, no 1 Hz tick.
    private func dismissBackground() {
        stopTicking()
        hideTrackChange()
        pauseToken?.cancel()
        pauseToken = nil
        if let backgroundID {
            islandPresenter.dismiss(backgroundID)
            self.backgroundID = nil
        }
    }

    // MARK: Presentations

    private func makeBackgroundPresentation(id: PresentationID) -> Presentation {
        Presentation(
            id: id,
            featureID: Self.featureID,
            title: Self.displayTitle,
            priority: .background,
            style: .peek,
            leading: viewFactory.leading(self),
            trailing: viewFactory.trailing(self),
            expanded: viewFactory.expanded(self),
            expandedSize: Self.expandedSize
        )
    }

    // MARK: Track-change banner

    /// Raises the banner flag and re-arms its timer, so consecutive skips each get a full peek.
    private func showTrackChange() {
        isShowingTrackChange = true
        trackChangeToken?.cancel()
        trackChangeToken = clock.schedule(after: Self.trackChangePeekDuration) { [weak self] in
            self?.hideTrackChange()
        }
    }

    private func hideTrackChange() {
        trackChangeToken?.cancel()
        trackChangeToken = nil
        isShowingTrackChange = false
    }

    // MARK: Commands

    public func perform(_ command: PlaybackCommand) {
        applyOptimistically(command)
        let send = sendCommand
        Task { await send(command) }
    }

    /// Reflects a transport command locally before the source echoes it back. The round trip
    /// (MediaRemote → helper debounce → XPC) takes 1-2 s, which reads as an unresponsive UI.
    /// The change is routed through `apply` so the pause timer, the presentation refresh and the
    /// track-change banner behave exactly as they do for a real snapshot (the title, artist and
    /// artwork are untouched, so nothing is treated as a track change). The next real snapshot
    /// overrides all of it.
    private func applyOptimistically(_ command: PlaybackCommand) {
        guard var optimistic = snapshot else {
            if case .seek(let seconds) = command { displayedElapsed = seconds }
            return
        }
        // Re-bases the projection on what is on screen so the next `tick()` freezes or resumes
        // from there instead of replaying the stale snapshot's elapsed. An unknown elapsed
        // stays unknown.
        func rebaseOnDisplayed(_ s: inout NowPlayingSnapshot) {
            if s.elapsed != nil { s.elapsed = displayedElapsed }
        }
        switch command {
        case .togglePlayPause:
            optimistic.playbackRate = isPlaying ? 0 : 1
            rebaseOnDisplayed(&optimistic)
        case .play:
            optimistic.playbackRate = 1
            rebaseOnDisplayed(&optimistic)
        case .pause:
            optimistic.playbackRate = 0
            rebaseOnDisplayed(&optimistic)
        case .seek(let seconds):
            optimistic.elapsed = seconds
        case .next, .previous:
            return  // the incoming track is unknown; wait for the real snapshot
        }
        optimistic.timestamp = now()
        apply(optimistic, isOptimistic: true)
    }

    // MARK: Progress ticking (only while the expanded view is visible)

    public func startTicking() {
        guard tickToken == nil else { return }
        tick()
    }

    public func stopTicking() {
        tickToken?.cancel()
        tickToken = nil
    }

    private func tick() {
        if let snapshot { displayedElapsed = PlaybackProgressTracker.elapsed(for: snapshot, at: now()) ?? 0 }
        tickToken = clock.schedule(after: .seconds(1)) { [weak self] in
            guard let self, self.tickToken != nil else { return }
            self.tick()
        }
    }
}
