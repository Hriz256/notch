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
    /// Identifies this connection's snapshot sink in the shared monitor.
    let clientToken = UUID()

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
        monitor.start(token: clientToken) { [weak self] snapshot in
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
        let logger = self.logger
        guard let client = connection.remoteObjectProxyWithErrorHandler({ error in
            logger.error("Client proxy call failed: \(error.localizedDescription, privacy: .public)")
        }) as? any NowPlayingHelperClientProtocol else {
            logger.error("Rejecting connection: client proxy does not implement the client protocol")
            return false
        }
        let service = HelperService(monitor: monitor, client: client)
        let token = service.clientToken
        connection.exportedObject = service
        // Without this the proxy keeps the connection alive and the connection keeps its exported
        // object: one leaked service plus connection per reconnect, and a dead proxy still being
        // called. Capture the monitor (a process-lifetime singleton) rather than the service, so
        // the handler itself adds no reference back into the connection's own object graph.
        connection.invalidationHandler = { [weak connection, monitor] in
            logger.notice("XPC connection invalidated: releasing the exported object")
            monitor?.stop(token: token)
            connection?.exportedObject = nil
        }
        connection.interruptionHandler = {
            logger.notice("XPC connection interrupted")
        }
        connection.resume()
        return true
    }
}
