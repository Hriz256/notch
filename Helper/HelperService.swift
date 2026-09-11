import Foundation
import os
import NowPlayingShared

/// One instance per XPC connection. Forwards commands to the shared monitor and
/// snapshots back to the connected app.
final class HelperService: NSObject, NowPlayingHelperProtocol, @unchecked Sendable {
    // @unchecked: `client` is set once on init; monitor is internally synchronized.
    private let logger = Logger(subsystem: "app.notch", category: "helper.service")
    private let monitor: NowPlayingMonitor?
    private let client: any NowPlayingHelperClientProtocol

    init(monitor: NowPlayingMonitor?, client: any NowPlayingHelperClientProtocol) {
        self.monitor = monitor
        self.client = client
    }

    func startMonitoring() {
        guard let monitor else {
            logger.error("MediaRemote unavailable: symbols could not be loaded")
            client.helperUnavailable("MediaRemote symbols could not be loaded")
            return
        }
        // `client` is a non-Sendable XPC proxy, so it is reached through `self` (which is
        // @unchecked Sendable) rather than captured directly. Weakly, so the monitor — which
        // outlives every connection — does not pin a dead connection's exported object.
        monitor.start { [weak self] snapshot in
            guard let self, let data = try? snapshot.encoded() else { return }
            client.snapshotDidChange(data)
        }
    }

    func requestFullState() { monitor?.requestFullState() }
    func play() { monitor?.send(.play) }
    func pause() { monitor?.send(.pause) }
    func togglePlayPause() { monitor?.send(.togglePlayPause) }
    func nextTrack() { monitor?.send(.nextTrack) }
    func previousTrack() { monitor?.send(.previousTrack) }
    func seek(toSeconds seconds: Double) { monitor?.seek(to: seconds) }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: "app.notch", category: "helper.service")
    private let monitor: NowPlayingMonitor?

    init(monitor: NowPlayingMonitor?) { self.monitor = monitor }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NowPlayingHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: NowPlayingHelperClientProtocol.self)
        guard let client = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? any NowPlayingHelperClientProtocol else {
            logger.error("Rejecting connection: client proxy does not implement the client protocol")
            return false
        }
        connection.exportedObject = HelperService(monitor: monitor, client: client)
        connection.resume()
        return true
    }
}
