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
    /// Identifies the connection that installed `sendSnapshot`, so a late `stop` from a connection
    /// that has already been replaced cannot silence the current client.
    private var sendToken: UUID?
    /// Bumped at the top of every `refresh()`. A refresh is two chained async round-trips, so a
    /// reply from an older refresh can land after a newer one; the stale reply is dropped instead
    /// of being published and becoming the dedup baseline.
    private var epoch: UInt64 = 0

    /// Info-did-change arrives in bursts (one per changed key), so those are coalesced.
    private static let debounce: DispatchTimeInterval = .milliseconds(150)
    /// Play/pause flips arrive as a single notification and are the most latency-visible change in
    /// the UI (the visualizer and the glyph), so they are refreshed without coalescing.
    private static let immediate: DispatchTimeInterval = .milliseconds(0)

    init(bridge: MediaRemoteBridge) {
        self.bridge = bridge
    }

    /// - Parameter token: identifies the calling connection; pass the same value to `stop(token:)`.
    func start(token: UUID, send: @escaping @Sendable (NowPlayingSnapshot) -> Void) {
        queue.async { [self] in
            if sendSnapshot != nil, sendToken != token {
                logger.notice("Replacing the snapshot sink of a previous client connection")
            }
            sendSnapshot = send
            sendToken = token
            // A (re)connecting client holds no state of its own. Without this reset, a client whose
            // last-seen snapshot matches the helper's cached one would be deduped into silence.
            dedup.reset()
            guard !isRegistered else { refresh(); return }
            isRegistered = true
            bridge.register(queue)
            let center = NotificationCenter.default
            for name in [MediaRemoteBridge.infoDidChange, MediaRemoteBridge.isPlayingDidChange, MediaRemoteBridge.applicationDidChange] {
                let delay: DispatchTimeInterval = name == MediaRemoteBridge.isPlayingDidChange ? Self.immediate : Self.debounce
                // Delivered on an unspecified queue; hop onto `queue` so all state stays confined.
                observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    queue.async { [weak self] in self?.scheduleRefresh(after: delay) }
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

    /// Drops the snapshot sink installed by `start(token:send:)` — only if it is still the one this
    /// token installed, so an invalidated connection cannot silence the client that replaced it.
    func stop(token: UUID) {
        queue.async { [self] in
            guard sendToken == token else { return }
            sendSnapshot = nil
            sendToken = nil
            logger.notice("Client disconnected: snapshot sink cleared")
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
            if !ok {
                logger.error("MediaRemote rejected command \(command.rawValue, privacy: .public)")
                // The app may have applied the command optimistically. Nothing actually changed, so
                // the corrective snapshot equals the last one sent and would be deduped into
                // silence, leaving the UI stuck in the wrong state.
                dedup.reset()
            }
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

    private func scheduleRefresh(after delay: DispatchTimeInterval = NowPlayingMonitor.debounce) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func refresh() {
        epoch &+= 1
        let current = epoch
        bridge.getInfo(queue) { [weak self] dict in
            // Every reply arrives on `queue`, so `epoch` is read under the same confinement it is
            // written under. A newer refresh having started means this reply is stale: drop it.
            guard let self, current == epoch else { return }
            let info = (dict as NSDictionary?) as? [String: Any] ?? [:]
            // The info dictionary's playback rate is unreliable (Spotify omits it or reports 0 while
            // playing), so the application-is-playing flag is fetched as the authoritative source.
            bridge.getIsPlaying(queue) { [weak self] isPlaying in
                guard let self, current == epoch else { return }
                // Both symbols are optional (see MediaRemoteBridge); without them the source app is unknown.
                guard let getClient = bridge.getClient, bridge.clientBundleID != nil else {
                    publish(info: info, isPlaying: isPlaying, bundleID: nil)
                    return
                }
                getClient(queue) { [weak self] client in
                    guard let self, current == epoch else { return }
                    // No client is the common "nothing is playing" state, and the bundle-id function
                    // must not be called with a NULL client.
                    guard let client else {
                        publish(info: info, isPlaying: isPlaying, bundleID: nil)
                        return
                    }
                    let bundleID = bridge.clientBundleID?(client)?.takeUnretainedValue() as String?
                    publish(info: info, isPlaying: isPlaying, bundleID: bundleID)
                }
            }
        }
    }

    private func publish(info: [String: Any], isPlaying: Bool, bundleID: String?) {
        let artwork = info[MediaRemoteBridge.InfoKey.artworkData] as? Data
        let artworkID = Self.artworkIdentifier(info[MediaRemoteBridge.InfoKey.artworkIdentifier], artwork: artwork)
        // `isPlaying` decides paused vs playing; the info rate only refines a playing rate (e.g. a
        // podcast at 0.75x or 1.5x), so sub-1x rates are kept as reported — flooring them to 1 would
        // make the progress projection run ahead and snap back on every snapshot. Only a missing,
        // non-finite or non-positive rate is treated as unknown and reads 1, since a rate of 0 or NaN
        // while playing means the source omits it, and `sanitized()` would flatten it to "paused".
        let rawRate = info[MediaRemoteBridge.InfoKey.playbackRate] as? Double
        let playbackRate: Double = isPlaying ? (rawRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1) : 0
        let snapshot = NowPlayingSnapshot(
            title: info[MediaRemoteBridge.InfoKey.title] as? String,
            artist: info[MediaRemoteBridge.InfoKey.artist] as? String,
            album: info[MediaRemoteBridge.InfoKey.album] as? String,
            artworkData: artwork,
            artworkID: artworkID,
            duration: info[MediaRemoteBridge.InfoKey.duration] as? Double,
            elapsed: info[MediaRemoteBridge.InfoKey.elapsedTime] as? Double,
            playbackRate: playbackRate,
            sourceBundleID: bundleID,
            timestamp: info[MediaRemoteBridge.InfoKey.timestamp] as? Date ?? Date()
        )
        // Sanitize before dedup: MediaRemote reports NaN durations for live streams, and NaN never
        // compares equal, so raw values would defeat `isEquivalent` and send on every notification.
        guard let prepared = dedup.prepare(snapshot.sanitized(), now: Date()) else { return }
        logger.debug("Snapshot: \(prepared.title ?? "-", privacy: .public) isPlaying=\(isPlaying, privacy: .public) rawRate=\(rawRate ?? .nan) rate=\(prepared.playbackRate) artwork=\(prepared.artworkData?.count ?? 0)B")
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
