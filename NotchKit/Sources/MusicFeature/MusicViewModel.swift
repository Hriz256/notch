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
    public static let expandedSize = CGSize(width: 390, height: 200)

    public private(set) var snapshot: NowPlayingSnapshot?
    public private(set) var artwork: Data?
    public private(set) var displayedElapsed: TimeInterval = 0

    public var isPlaying: Bool { snapshot?.isPlaying ?? false }
    public var duration: TimeInterval { snapshot?.duration ?? 0 }

    @ObservationIgnored private let presenter: any IslandPresenting
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private let sendCommand: @Sendable (PlaybackCommand) async -> Void
    @ObservationIgnored private let viewFactory: MusicViewFactory
    @ObservationIgnored private var backgroundID: PresentationID?
    @ObservationIgnored private var pauseToken: ScheduledToken?
    @ObservationIgnored private var tickToken: ScheduledToken?

    public init(presenter: any IslandPresenting,
                clock: any IslandClock,
                sendCommand: @escaping @Sendable (PlaybackCommand) async -> Void,
                viewFactory: MusicViewFactory) {
        self.presenter = presenter
        self.clock = clock
        self.sendCommand = sendCommand
        self.viewFactory = viewFactory
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
        displayedElapsed = PlaybackProgressTracker.elapsed(for: new, at: Date()) ?? 0

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

        if trackChanged, new.isPlaying {
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

    private func dismissBackground() {
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
            expanded: nil
        )
    }

    // MARK: Commands

    public func perform(_ command: PlaybackCommand) {
        if case .seek(let seconds) = command { displayedElapsed = seconds }
        let send = sendCommand
        Task { await send(command) }
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
        if let snapshot { displayedElapsed = PlaybackProgressTracker.elapsed(for: snapshot, at: Date()) ?? 0 }
        tickToken = clock.schedule(after: .seconds(1)) { [weak self] in
            guard let self, self.tickToken != nil else { return }
            self.tick()
        }
    }
}
