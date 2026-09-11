import Foundation
import os
import NowPlayingShared

/// Chooses between the XPC helper and the AppleScript fallback and exposes one event stream.
public actor NowPlayingCoordinator {
    private let logger = Logger(subsystem: "app.notch", category: "nowplaying.coordinator")
    private let primary: any NowPlayingSource
    private let fallback: any NowPlayingSource
    private let probe: @Sendable () async -> Bool
    private let silenceTimeout: Duration

    private var active: any NowPlayingSource
    private var forwardTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var continuation: AsyncStream<NowPlayingEvent>.Continuation?
    private var receivedSnapshot = false

    public var activeSourceName: String { active.name }

    public init(primary: any NowPlayingSource,
                fallback: any NowPlayingSource,
                probe: @escaping @Sendable () async -> Bool,
                silenceTimeout: Duration = .seconds(5)) {
        self.primary = primary
        self.fallback = fallback
        self.probe = probe
        self.silenceTimeout = silenceTimeout
        self.active = primary
    }

    /// Call once before `start()`. A second call replaces the continuation, so the earlier
    /// stream stops receiving events.
    public func events() -> AsyncStream<NowPlayingEvent> {
        AsyncStream { c in self.continuation = c }
    }

    public func start() async {
        await activate(primary)
        armSilenceWatch()
    }

    public func stop() async {
        forwardTask?.cancel()
        silenceTask?.cancel()
        await active.stop()
        continuation?.finish()
    }

    public func send(_ command: PlaybackCommand) async {
        await active.send(command)
    }

    // MARK: Private

    private func activate(_ source: any NowPlayingSource) async {
        forwardTask?.cancel()
        active = source
        receivedSnapshot = false
        let stream = source.events()
        await source.start()
        forwardTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event, from: source.name)
            }
        }
        logger.info("Active source: \(source.name, privacy: .public)")
    }

    private func handle(_ event: NowPlayingEvent, from sourceName: String) async {
        guard sourceName == active.name else { return }
        switch event {
        case .snapshot:
            receivedSnapshot = true
            silenceTask?.cancel()
            continuation?.yield(event)
        case .unavailable(let reason):
            if active.name == primary.name {
                logger.error("Primary unavailable (\(reason, privacy: .public)); switching to fallback")
                await switchToFallback()
            } else {
                continuation?.yield(event)
            }
        }
    }

    private func switchToFallback() async {
        silenceTask?.cancel()
        await primary.stop()
        await activate(fallback)
    }

    private func armSilenceWatch() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.silenceTimeout)
            guard !Task.isCancelled else { return }
            await self.checkSilence()
        }
    }

    private func checkSilence() async {
        guard active.name == primary.name, !receivedSnapshot else { return }
        if await probe() {
            logger.notice("Primary silent while media is playing; switching to fallback")
            await switchToFallback()
        }
    }
}
