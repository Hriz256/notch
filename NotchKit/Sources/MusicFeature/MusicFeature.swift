import SwiftUI
import os
import IslandCore
import NowPlayingClient

/// Registers with the island, owns the now-playing coordinator and forwards its events.
@MainActor
public final class MusicFeature: IslandFeature {
    public let id = MusicViewModel.featureID
    private let logger = Logger(subsystem: "app.notch", category: "music")
    private var coordinator: NowPlayingCoordinator?
    private var model: MusicViewModel?
    private var eventTask: Task<Void, Never>?

    public init() {}

    public func activate(presenter: any IslandPresenting) {
        deactivate()
        let coordinator = NowPlayingCoordinator(
            primary: XPCNowPlayingSource(),
            fallback: AppleScriptNowPlayingSource(),
            probe: { await AppleScriptNowPlayingSource.isAnythingPlaying() }
        )
        let model = MusicViewModel(
            presenter: presenter,
            clock: TaskClock(),
            sendCommand: { command in await coordinator.send(command) },
            viewFactory: Self.viewFactory
        )
        self.coordinator = coordinator
        self.model = model
        eventTask = Task { [weak self] in
            let stream = await coordinator.events()
            await coordinator.start()
            for await event in stream {
                guard let self else { return }
                await MainActor.run { self.model?.handle(event) }
            }
        }
        logger.info("Music feature activated")
    }

    public func deactivate() {
        eventTask?.cancel()
        eventTask = nil
        if let coordinator { Task { await coordinator.stop() } }
        model?.handle(.unavailable("deactivated"))
        coordinator = nil
        model = nil
    }

    private static let viewFactory = MusicViewFactory(
        leading: { AnyView(MusicCompactLeading(model: $0)) },
        trailing: { AnyView(MusicCompactTrailing(model: $0)) },
        expanded: { AnyView(MusicExpandedView(model: $0)) }
    )
}
