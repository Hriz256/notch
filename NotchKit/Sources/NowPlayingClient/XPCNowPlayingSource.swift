import Foundation
import os
import NowPlayingShared

/// Talks to the embedded NotchHelper XPC service.
public final class XPCNowPlayingSource: NowPlayingSource, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    public let name = "xpc"
    private let logger = Logger(subsystem: "app.notch", category: "nowplaying.xpc")
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var continuation: AsyncStream<NowPlayingEvent>.Continuation?
    private var reconnectTask: Task<Void, Never>?
    private var isRunning = false
    private var retries = 0
    private static let maxRetries = 5

    public init() {}

    public func events() -> AsyncStream<NowPlayingEvent> {
        AsyncStream { c in self.lock.withLock { self.continuation = c } }
    }

    public func start() async {
        lock.withLock { isRunning = true }
        connect()
    }

    public func stop() async {
        // Take the connection out under the lock and invalidate it outside: the invalidation
        // handler runs on another queue and would otherwise contend for the same lock.
        let connection = lock.withLock { () -> NSXPCConnection? in
            isRunning = false
            reconnectTask?.cancel()
            reconnectTask = nil
            let dropped = self.connection
            self.connection = nil
            continuation?.finish()
            continuation = nil
            return dropped
        }
        connection?.invalidate()
    }

    public func send(_ command: PlaybackCommand) async {
        guard let proxy = proxy() else { return }
        switch command {
        case .play: proxy.play()
        case .pause: proxy.pause()
        case .togglePlayPause: proxy.togglePlayPause()
        case .next: proxy.nextTrack()
        case .previous: proxy.previousTrack()
        case .seek(let seconds): proxy.seek(toSeconds: seconds)
        }
    }

    // MARK: Private

    private func proxy() -> (any NowPlayingHelperProtocol)? {
        let connection = lock.withLock { self.connection }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.logger.error("XPC proxy error: \(error.localizedDescription, privacy: .public)")
        } as? any NowPlayingHelperProtocol
    }

    private func connect() {
        // A reconnect scheduled before `stop()` must not resurrect a stopped source.
        guard lock.withLock({ isRunning }) else { return }
        let connection = NSXPCConnection(serviceName: NowPlayingXPC.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: NowPlayingHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: NowPlayingHelperClientProtocol.self)
        connection.exportedObject = ClientReceiver { [weak self] event in self?.emit(event) }
        // The connection is captured weakly: it owns these handlers, so a strong capture would
        // be a retain cycle. Passing it lets `handleDrop` ignore a handler from a dead connection.
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.handleDrop(reason: "interrupted", dropped: connection)
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.handleDrop(reason: "invalidated", dropped: connection)
        }
        let previous = lock.withLock { () -> NSXPCConnection? in
            let previous = self.connection
            self.connection = connection
            return previous
        }
        // Tear the old one down; its handlers no-op because it is no longer `self.connection`.
        previous?.invalidate()
        connection.resume()
        // Fire-and-forget; delivery failures surface through the proxy error handler.
        proxy()?.startMonitoring()
        logger.info("Connected to helper")
    }

    private func handleDrop(reason: String, dropped: NSXPCConnection) {
        let attempt = lock.withLock { () -> Int? in
            // Stale handler: this connection was already replaced, so the live one must survive.
            guard connection === dropped else { return nil }
            connection = nil
            guard isRunning else { return nil }
            retries += 1
            return retries
        }
        guard let attempt else { return }
        guard attempt <= Self.maxRetries else {
            emit(.unavailable("helper connection \(reason) after \(Self.maxRetries) retries"))
            return
        }
        let delay = min(8.0, 0.5 * pow(2.0, Double(attempt - 1)))
        logger.notice("Helper \(reason, privacy: .public); reconnecting in \(delay)s")
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
        lock.withLock {
            reconnectTask?.cancel()
            // `stop()` may have won the race; then the new task is cancelled, not stored.
            if isRunning { reconnectTask = task } else { task.cancel() }
        }
    }

    private func emit(_ event: NowPlayingEvent) {
        if case .snapshot = event { lock.withLock { retries = 0 } }
        lock.withLock { continuation }?.yield(event)
    }
}

private final class ClientReceiver: NSObject, NowPlayingHelperClientProtocol, @unchecked Sendable {
    // @unchecked: `handler` is an immutable @Sendable closure; NSObject is not formally Sendable.
    private let handler: @Sendable (NowPlayingEvent) -> Void
    init(handler: @escaping @Sendable (NowPlayingEvent) -> Void) { self.handler = handler }

    func snapshotDidChange(_ data: Data) {
        guard let snapshot = try? NowPlayingSnapshot.decode(data) else { return }
        handler(.snapshot(snapshot))
    }

    func helperUnavailable(_ reason: String) {
        handler(.unavailable(reason))
    }
}
