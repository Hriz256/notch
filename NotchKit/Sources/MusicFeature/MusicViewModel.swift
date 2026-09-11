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
    public static let pauseDismissDelay: Duration = .seconds(600)
    public static let trackChangePeekDuration: Duration = .seconds(2.5)
    public static let expandedSize = CGSize(width: 380, height: 160)
    /// UserDefaults key backing the "Track change peek" setting (absent means on).
    public nonisolated static let trackChangePeekDefaultsKey = "music.trackChangePeek"

    public private(set) var snapshot: NowPlayingSnapshot?
    public private(set) var artwork: Data?
    public private(set) var displayedElapsed: TimeInterval = 0

    public var isPlaying: Bool { snapshot?.isPlaying ?? false }
    public var duration: TimeInterval { snapshot?.duration ?? 0 }

    @ObservationIgnored private let presenter: any IslandPresenting
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
        self.presenter = presenter
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

    private func apply(_ new: NowPlayingSnapshot) {
        let old = snapshot
        mergeArtwork(from: new)
        snapshot = new
        displayedElapsed = PlaybackProgressTracker.elapsed(for: new, at: now()) ?? 0

        guard new.hasTrack else {
            dismissBackground()
            return
        }

        let trackChanged = old.map { $0.title != new.title || $0.artist != new.artist || $0.artworkID != new.artworkID } ?? false

        if let backgroundID {
            presenter.update(makeBackgroundPresentation(id: backgroundID))
        } else {
            let id = PresentationID()
            backgroundID = id
            presenter.present(makeBackgroundPresentation(id: id))
        }

        if trackChanged, new.isPlaying, isTrackChangePeekEnabled() {
            presenter.present(makeTrackChangePeek())
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
        pauseToken?.cancel()
        pauseToken = nil
        if let backgroundID {
            presenter.dismiss(backgroundID)
            self.backgroundID = nil
        }
    }

    // MARK: Presentations

    private func makeBackgroundPresentation(id: PresentationID) -> Presentation {
        Presentation(
            id: id,
            featureID: Self.featureID,
            priority: .background,
            style: .peek,
            leading: viewFactory.leading(self),
            trailing: viewFactory.trailing(self),
            expanded: viewFactory.expanded(self),
            expandedSize: Self.expandedSize
        )
    }

    private func makeTrackChangePeek() -> Presentation {
        Presentation(
            featureID: Self.featureID,
            priority: .activity,
            style: .peek,
            ttl: Self.trackChangePeekDuration,
            leading: viewFactory.leading(self),
            trailing: viewFactory.trailing(self),
            // Carries the expanded view so the peek stays hover-eligible: otherwise the presenter
            // clears hover promotion and an open panel would collapse under the pointer.
            expanded: viewFactory.expanded(self),
            expandedSize: Self.expandedSize
        )
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
    /// track-change peek behave exactly as they do for a real snapshot (the title, artist and
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
        apply(optimistic)
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
