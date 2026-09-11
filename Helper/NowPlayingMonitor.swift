import Foundation
import CryptoKit
import os
import NowPlayingShared

/// Listens to MediaRemote, builds snapshots, dedups/debounces and forwards them to the app.
final class NowPlayingMonitor: @unchecked Sendable {
    // @unchecked: all mutable state is confined to `queue`.

    private let logger = Logger(subsystem: "app.notch", category: "helper.monitor")
    private let bridge: MediaRemoteBridge
    private let queue = DispatchQueue(label: "app.notch.helper.monitor")
    private var dedup = SnapshotDedup()
    private var pendingRefresh: DispatchWorkItem?
    private var observers: [any NSObjectProtocol] = []
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var isRegistered = false
    private var sendSnapshot: (@Sendable (NowPlayingSnapshot) -> Void)?

    private static let debounce: DispatchTimeInterval = .milliseconds(150)

    init(bridge: MediaRemoteBridge) {
        self.bridge = bridge
    }

    func start(send: @escaping @Sendable (NowPlayingSnapshot) -> Void) {
        queue.async { [self] in
            sendSnapshot = send
            // A (re)connecting client holds no state of its own. Without this reset, a client whose
            // last-seen snapshot matches the helper's cached one would be deduped into silence.
            dedup.reset()
            guard !isRegistered else { refresh(); return }
            isRegistered = true
            bridge.register(queue)
            let center = NotificationCenter.default
            for name in [MediaRemoteBridge.infoDidChange, MediaRemoteBridge.isPlayingDidChange, MediaRemoteBridge.applicationDidChange] {
                // Delivered on an unspecified queue; hop onto `queue` so all state stays confined.
                observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    queue.async { [weak self] in self?.scheduleRefresh() }
                })
            }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                dedup.reset()
                logger.notice("Memory pressure: artwork cache reset")
            }
            source.resume()
            memoryPressure = source
            refresh()
        }
    }

    func requestFullState() {
        queue.async { [self] in
            dedup.reset()
            refresh()
        }
    }

    func send(_ command: MediaRemoteBridge.Command) {
        queue.async { [self] in
            let ok = bridge.sendCommand(command.rawValue, nil)
            if !ok { logger.error("MediaRemote rejected command \(command.rawValue, privacy: .public)") }
            scheduleRefresh()
        }
    }

    func seek(to seconds: Double) {
        queue.async { [self] in
            bridge.setElapsed(seconds)
            scheduleRefresh()
        }
    }

    // MARK: Private (on `queue`)

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = item
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }

    private func refresh() {
        bridge.getInfo(queue) { [weak self] dict in
            guard let self else { return }
            let info = (dict as NSDictionary?) as? [String: Any] ?? [:]
            // Both symbols are optional (see MediaRemoteBridge); without them the source app is unknown.
            guard let getClient = bridge.getClient, bridge.clientBundleID != nil else {
                publish(info: info, bundleID: nil)
                return
            }
            getClient(queue) { [weak self] client in
                guard let self else { return }
                let bundleID = bridge.clientBundleID?(client)?.takeUnretainedValue() as String?
                publish(info: info, bundleID: bundleID)
            }
        }
    }

    private func publish(info: [String: Any], bundleID: String?) {
        let artwork = info[MediaRemoteBridge.InfoKey.artworkData] as? Data
        let artworkID = Self.artworkIdentifier(info[MediaRemoteBridge.InfoKey.artworkIdentifier], artwork: artwork)
        let snapshot = NowPlayingSnapshot(
            title: info[MediaRemoteBridge.InfoKey.title] as? String,
            artist: info[MediaRemoteBridge.InfoKey.artist] as? String,
            album: info[MediaRemoteBridge.InfoKey.album] as? String,
            artworkData: artwork,
            artworkID: artworkID,
            duration: info[MediaRemoteBridge.InfoKey.duration] as? Double,
            elapsed: info[MediaRemoteBridge.InfoKey.elapsedTime] as? Double,
            playbackRate: info[MediaRemoteBridge.InfoKey.playbackRate] as? Double ?? 0,
            sourceBundleID: bundleID,
            timestamp: info[MediaRemoteBridge.InfoKey.timestamp] as? Date ?? Date()
        )
        guard let prepared = dedup.prepare(snapshot, now: Date()) else { return }
        logger.debug("Snapshot: \(prepared.title ?? "-", privacy: .public) rate=\(prepared.playbackRate) artwork=\(prepared.artworkData?.count ?? 0)B")
        sendSnapshot?(prepared)
    }

    /// MediaRemote reports the artwork identifier as a string on some sources and as a number on
    /// others, and omits it entirely on a few. When it is missing but bytes are present, a digest of
    /// the bytes stands in, so artwork data is never sent with a nil id (the dedup keys on the id).
    private static func artworkIdentifier(_ raw: Any?, artwork: Data?) -> String? {
        if let string = raw as? String, !string.isEmpty { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return artwork.map(digest)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
