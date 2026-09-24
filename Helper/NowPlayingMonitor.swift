import Foundation
import CryptoKit
import os
import NowPlayingShared

/// Listens to MediaRemote, builds snapshots, dedups/debounces and forwards them to the app.
///
/// It follows the player you hear, not the one macOS elected: macOS elects whoever most recently
/// *started* playing and keeps it through a pause, so a 0.2 s sound in a Chrome tab would hide a
/// playing Spotify. Every listed player's own state goes through `PlayerChoice`, and the buttons
/// go to the player it picks. Without the per-client MediaRemote calls it falls back to the
/// elected player (`refreshElectedOnly()`).
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
    /// Bumped at the top of every refresh, and by every command sent to the followed player (see
    /// `sendToFollowedPlayer`). A refresh is a chain of async round-trips, so a reply from an older
    /// refresh can land after a newer one; the stale reply is dropped instead of being published
    /// and becoming the dedup baseline.
    private var epoch: UInt64 = 0
    /// Which listed player the island follows. Survives reconnects, full-state requests and memory
    /// pressure on purpose: forgetting it would make the island jump to the elected player.
    private var choice = PlayerChoice()
    /// The `MRClient` of `choice`'s player, so play/pause/next/previous/seek reach the player the
    /// island shows, not the elected one. nil on the elected-only path and when nothing is listed.
    private var followedClient: AnyObject?
    /// Refreshes when a challenger's takeover delay runs out, which no notification marks. Its own
    /// item, so a notification's debounce (`pendingRefresh`) cannot cancel it.
    private var pendingRecheck: DispatchWorkItem?
    /// The one follow-up refresh for a track whose artwork bytes were missing (see
    /// `followUpMissingArtwork`), and the track it was scheduled for.
    private var pendingArtworkRefresh: DispatchWorkItem?
    private var artworkFollowUpTrack: TrackKey?
    /// The corrective refresh after a command to the followed player (see `sendToFollowedPlayer`).
    /// Its own item, so a notification's debounce (`pendingRefresh`) cannot cancel it.
    private var pendingCorrection: DispatchWorkItem?
    /// The last snapshot handed to the client. Its projection is the position the UI is showing,
    /// and it is what a play/pause flip re-bases on when MediaRemote's own pair is stale.
    private var lastPublished: NowPlayingSnapshot?
    /// Play state of the previous publish, so a true→false / false→true flip can be recognised.
    private var lastIsPlaying: Bool?
    /// When the flip to paused / to playing was observed. MediaRemote's info dictionary carries an
    /// `ElapsedTime` valid at `Timestamp`, and sources (Spotify) frequently do not refresh that
    /// pair when the transport state changes: the pair still describes a moment *before* the flip.
    /// Reading it as-is with rate 0 would freeze the display at that older position — the elapsed
    /// time visibly jumping backwards on pause. These two dates date the flip so a pre-flip pair
    /// can be recognised and replaced by the position actually on screen.
    private var pauseObservedAt: Date?
    private var resumeObservedAt: Date?

    /// Info-did-change arrives in bursts (one per changed key), so those are coalesced.
    private static let debounce: DispatchTimeInterval = .milliseconds(150)
    /// Play/pause flips arrive as a single notification and are the most latency-visible change in
    /// the UI (the visualizer and the glyph), so they are refreshed without coalescing.
    private static let immediate: DispatchTimeInterval = .milliseconds(0)
    /// A recheck lands this far past `recheckAt`, so timer and clock jitter cannot run the decision
    /// a hair before the challenger's delay is over and leave it waiting for the next notification.
    private static let recheckSlack: TimeInterval = 0.05
    /// A player that is not elected can answer its first info request without artwork and with it
    /// a moment later (spike: 0 B, then 188 KB on every later call).
    private static let artworkRetry: DispatchTimeInterval = .seconds(1)
    /// How long after a command to the followed player its corrective snapshot is sent. The player
    /// applies a command on its own time (Spotify pauses 0.3–0.45 s after it), so a refresh sooner
    /// than that can still read the state the command is changing.
    private static let commandCorrectionDelay: DispatchTimeInterval = .seconds(1)

    /// One entry of MediaRemote's client list, as one refresh sees it.
    private struct Player {
        let client: AnyObject
        /// Unique within the list, which `PlayerChoice` assumes; see `players(in:)`.
        let id: String
        /// What the snapshot publishes as `sourceBundleID`.
        let bundleID: String?
        let pid: Int32?
    }

    /// A track as far as the artwork follow-up is concerned.
    private struct TrackKey: Equatable {
        let bundleID: String?
        let title: String
        let artist: String?
    }

    init(bridge: MediaRemoteBridge) {
        self.bridge = bridge
    }

    /// Whether this macOS has everything the per-client path needs: the five per-client calls and
    /// the client bundle id that player ids are made of.
    private var followsPlayers: Bool { bridge.perClient != nil && bridge.clientBundleID != nil }

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
            // `choice` is kept: a reconnecting app must not see the island jump to the elected player.
            dedup.reset()
            guard !isRegistered else { refresh(); return }
            isRegistered = true
            bridge.register(queue)
            var names = [MediaRemoteBridge.infoDidChange, MediaRemoteBridge.isPlayingDidChange, MediaRemoteBridge.applicationDidChange]
            if followsPlayers {
                // The players that are not elected post only these, so only the per-client path
                // listens; the elected-only fallback stays as it was.
                names += [MediaRemoteBridge.playerInfoDidChange, MediaRemoteBridge.playerIsPlayingDidChange,
                          MediaRemoteBridge.playerPlaybackStateDidChange, MediaRemoteBridge.applicationDidUnregister]
            } else {
                var missing: [String] = []
                if bridge.perClient == nil { missing.append("the per-client calls") }
                if bridge.clientBundleID == nil { missing.append("MRNowPlayingClientGetBundleIdentifier") }
                logger.notice("MediaRemote lacks \(missing.joined(separator: " and "), privacy: .public): following the player macOS elected")
            }
            let flips = [MediaRemoteBridge.isPlayingDidChange, MediaRemoteBridge.playerIsPlayingDidChange,
                         MediaRemoteBridge.playerPlaybackStateDidChange]
            let center = NotificationCenter.default
            for name in names {
                let delay: DispatchTimeInterval = flips.contains(name) ? Self.immediate : Self.debounce
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

    /// Resends everything; `choice` is kept, so the island stays on the player it follows.
    func requestFullState() {
        queue.async { [self] in
            dedup.reset()
            refresh()
        }
    }

    func send(_ command: MediaRemoteBridge.Command) {
        queue.async { [self] in
            // Only the elected path can report a rejection; see `sendToFollowedPlayer`.
            let ok = sendToFollowedPlayer(command) || bridge.sendCommand(command.rawValue, nil)
            if !ok { commandRejected(command) }
            scheduleRefresh()
        }
    }

    func seek(to seconds: Double) {
        queue.async { [self] in
            let options = [MediaRemoteBridge.playbackPositionOption: seconds] as CFDictionary
            if !sendToFollowedPlayer(.seekToPlaybackPosition, options: options) {
                bridge.setElapsed(seconds)
            }
            scheduleRefresh()
        }
    }

    // MARK: Private (on `queue`)

    /// Sends `command` to the player the island follows. false when there is none (the elected-only
    /// path, or nothing listed): the caller then addresses macOS's elected player, as before.
    ///
    /// true means only that it was sent. `MRMediaRemoteSendCommandToClient` returns 1 whatever the
    /// player does (it sets `w0` to 1 right before its only return), so a player that ignores the
    /// command cannot be told from one that obeys. A corrective refresh `commandCorrectionDelay`
    /// later resets the dedup first, as for a rejected command, so it always sends a snapshot: that
    /// corrects the app's optimistic state if the player ignored the command.
    ///
    /// The reset waits for the player. The refresh the caller schedules 150 ms after a pause still
    /// reads Spotify playing; deduped, that read is dropped as the snapshot the app already had,
    /// but after a reset it reached the app and flipped the optimistic glyph to pause and back.
    private func sendToFollowedPlayer(_ command: MediaRemoteBridge.Command, options: CFDictionary? = nil) -> Bool {
        guard let calls = bridge.perClient, let followedClient else { return false }
        // Looked up per command, as per refresh: MediaRemote owns the local origin (it comes back
        // unretained), and this local holds it for the call.
        let origin = calls.getLocalOrigin()?.takeUnretainedValue()
        // Always 1, so not read (see above).
        _ = calls.sendCommand(UInt32(command.rawValue), options, origin, followedClient, 0, queue) { _ in }
        // A refresh already in flight may have read the player before the command. A snapshot of it that the
        // dedup lets through (new artwork bytes, say) would still carry the old play state and flip
        // the optimistic glyph back; bumping the epoch drops its replies at their next guard.
        epoch &+= 1
        scheduleCorrection()
        return true
    }

    /// Replaces the pending correction, so after a burst of commands the last one gets the full delay.
    private func scheduleCorrection() {
        pendingCorrection?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            dedup.reset()
            refresh()
        }
        pendingCorrection = item
        queue.asyncAfter(deadline: .now() + Self.commandCorrectionDelay, execute: item)
    }

    private func commandRejected(_ command: MediaRemoteBridge.Command) {
        logger.error("MediaRemote rejected command \(command.rawValue, privacy: .public)")
        // The app may have applied the command optimistically. Nothing actually changed, so
        // the corrective snapshot equals the last one sent and would be deduped into
        // silence, leaving the UI stuck in the wrong state.
        dedup.reset()
    }

    private func scheduleRefresh(after delay: DispatchTimeInterval = NowPlayingMonitor.debounce) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Lists every now-playing client, reads each one's own state, lets `choice` pick one and
    /// publishes that one's info. Falls back to `refreshElectedOnly()` without the per-client calls.
    private func refresh() {
        guard followsPlayers, let calls = bridge.perClient else {
            refreshElectedOnly()
            return
        }
        epoch &+= 1
        let current = epoch
        // Taken per refresh rather than kept: MediaRemote owns the local origin (it comes back
        // unretained), and this strong local holds it for every call of this refresh.
        let origin = calls.getLocalOrigin()?.takeUnretainedValue()
        calls.getClients(queue) { [weak self] list in
            // Every reply arrives on `queue`, so `epoch` is read under the same confinement it is
            // written under. A newer refresh having started means this reply is stale: drop it.
            guard let self, current == epoch else { return }
            let players = players(in: list as? [AnyObject] ?? [])
            // The elected player only breaks ties; without the symbol there is none to break them.
            guard let getClient = bridge.getClient else {
                follow(players, elected: nil, origin: origin, calls: calls, epoch: current)
                return
            }
            getClient(queue) { [weak self] elected in
                guard let self, current == epoch else { return }
                follow(players, elected: electedID(elected, in: players), origin: origin, calls: calls, epoch: current)
            }
        }
    }

    /// Reads every player's own state in parallel, lets `choice` pick one and publishes it. With
    /// nothing listed, `choice` picks nothing and the card goes, as with no elected client.
    private func follow(_ players: [Player], elected: String?, origin: AnyObject?,
                        calls: MediaRemoteBridge.PerClient, epoch current: UInt64) {
        // The replies land on `queue`, like every reply here, so the shared array needs no lock.
        var states = [UInt32?](repeating: nil, count: players.count)
        let group = DispatchGroup()
        for (index, player) in players.enumerated() {
            group.enter()
            calls.getPlaybackState(player.client, origin, queue) { state in
                // No epoch check: this touches only this refresh's own `states` and must balance
                // the group; the notify that acts on them is checked. A second reply for one
                // client would unbalance the group, which traps.
                guard states[index] == nil else { return }
                states[index] = state
                group.leave()
            }
        }
        group.notify(queue: queue) { [weak self] in
            guard let self, current == epoch else { return }
            let isPlaying = states.map { $0 == MediaRemoteBridge.PlaybackState.playing }
            let candidates = zip(players, isPlaying).map { PlayerChoice.Candidate(id: $0.id, isPlaying: $1) }
            let previous = choice.shownID
            let decision = choice.decide(candidates, elected: elected, now: Date())
            if decision.playerID != previous {
                logger.notice("Following \(decision.playerID ?? "-", privacy: .public) (elected \(elected ?? "-", privacy: .public))")
            }
            scheduleRecheck(at: decision.recheckAt)
            guard let index = players.firstIndex(where: { $0.id == decision.playerID }) else {
                followedClient = nil
                publish(info: [:], isPlaying: false, bundleID: nil)
                return
            }
            let player = players[index]
            followedClient = player.client
            calls.getInfo(player.client, origin, true, queue) { [weak self] dict in
                guard let self, current == epoch else { return }
                let info = (dict as NSDictionary?) as? [String: Any] ?? [:]
                publish(info: info, isPlaying: isPlaying[index], bundleID: player.bundleID)
                followUpMissingArtwork(in: info, bundleID: player.bundleID)
            }
        }
    }

    /// Replaces the pending recheck; nil cancels it, since no challenger is waiting any more.
    private func scheduleRecheck(at date: Date?) {
        pendingRecheck?.cancel()
        pendingRecheck = nil
        guard let date else { return }
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRecheck = item
        queue.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow) + Self.recheckSlack, execute: item)
    }

    /// A titled track without artwork bytes gets one more refresh `artworkRetry` later, so its
    /// cover does not wait for the next notification. Once per track: Chrome items never have
    /// artwork, and they cost one extra refresh each rather than one every second.
    private func followUpMissingArtwork(in info: [String: Any], bundleID: String?) {
        guard let title = info[MediaRemoteBridge.InfoKey.title] as? String, !title.isEmpty,
              (info[MediaRemoteBridge.InfoKey.artworkData] as? Data)?.isEmpty ?? true
        else { return }
        let track = TrackKey(bundleID: bundleID, title: title, artist: info[MediaRemoteBridge.InfoKey.artist] as? String)
        guard track != artworkFollowUpTrack else { return }
        artworkFollowUpTrack = track
        // Replaces only an earlier track's follow-up, which no longer matters: that track is gone.
        pendingArtworkRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingArtworkRefresh = item
        queue.asyncAfter(deadline: .now() + Self.artworkRetry, execute: item)
    }

    /// MediaRemote's client list in its own order, with ids unique within it (`PlayerChoice` keys
    /// on them): the bundle id; `<bundle id>#<pid>` for a second process of the same app;
    /// `pid-<pid>` for a client without a bundle id.
    private func players(in clients: [AnyObject]) -> [Player] {
        var taken = Set<String>()
        return clients.enumerated().map { index, client in
            let bundleID = bundleID(of: client)
            let pid = bridge.clientPID?(client)
            let pidText = pid.map(String.init) ?? "?"
            var id = bundleID ?? "pid-\(pidText)"
            if taken.contains(id) { id += "#\(pidText)" }
            // Still taken only without the pid symbol, or for one process listed twice.
            if taken.contains(id) { id += "#\(index)" }
            taken.insert(id)
            return Player(client: client, id: id, bundleID: bundleID, pid: pid)
        }
    }

    /// The id of macOS's elected client among `players`: the entry of the same process, else the
    /// first of the same app. nil when there is no elected client or it is not listed.
    private func electedID(_ elected: AnyObject?, in players: [Player]) -> String? {
        // The client functions must not be called with a NULL client.
        guard let elected else { return nil }
        let bundleID = bundleID(of: elected)
        let pid = bridge.clientPID?(elected)
        let entry = players.first { $0.bundleID == bundleID && $0.pid == pid }
            ?? players.first { bundleID != nil && $0.bundleID == bundleID }
        return entry?.id
    }

    private func bundleID(of client: AnyObject) -> String? {
        guard let id = bridge.clientBundleID?(client)?.takeUnretainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }

    /// macOS's elected player only — its info, its is-playing flag, its bundle id — for a macOS
    /// without the per-client calls. The path the helper had before it could tell players apart.
    private func refreshElectedOnly() {
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
        let now = Date()
        // A flip is one player's: switching players is not a pause or a resume of either.
        if bundleID != lastPublished?.sourceBundleID {
            lastIsPlaying = nil
            pauseObservedAt = nil
            resumeObservedAt = nil
        }
        recordTransportFlip(isPlaying: isPlaying, at: now)
        let artwork = info[MediaRemoteBridge.InfoKey.artworkData] as? Data
        let artworkID = Self.artworkIdentifier(info[MediaRemoteBridge.InfoKey.artworkIdentifier], artwork: artwork)
        // `isPlaying` decides paused vs playing; the info rate only refines a playing rate (e.g. a
        // podcast at 0.75x or 1.5x), so sub-1x rates are kept as reported — flooring them to 1 would
        // make the progress projection run ahead and snap back on every snapshot. Only a missing,
        // non-finite or non-positive rate is treated as unknown and reads 1, since a rate of 0 or NaN
        // while playing means the source omits it, and `sanitized()` would flatten it to "paused".
        let rawRate = info[MediaRemoteBridge.InfoKey.playbackRate] as? Double
        let playbackRate: Double = isPlaying ? (rawRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1) : 0
        var snapshot = NowPlayingSnapshot(
            title: info[MediaRemoteBridge.InfoKey.title] as? String,
            artist: info[MediaRemoteBridge.InfoKey.artist] as? String,
            album: info[MediaRemoteBridge.InfoKey.album] as? String,
            artworkData: artwork,
            artworkID: artworkID,
            duration: info[MediaRemoteBridge.InfoKey.duration] as? Double,
            elapsed: info[MediaRemoteBridge.InfoKey.elapsedTime] as? Double,
            playbackRate: playbackRate,
            sourceBundleID: bundleID,
            timestamp: info[MediaRemoteBridge.InfoKey.timestamp] as? Date ?? now
        )
        rebaseOnFlipIfPairIsStale(&snapshot, isPlaying: isPlaying)
        // Sanitize before dedup: MediaRemote reports NaN durations for live streams, and NaN never
        // compares equal, so raw values would defeat `isEquivalent` and send on every notification.
        let sanitized = snapshot.sanitized()
        // The projection base only reads elapsed/rate/timestamp, so it is kept without the artwork
        // bytes rather than holding an album cover alive for the lifetime of the track.
        var base = sanitized
        base.artworkData = nil
        defer { lastPublished = base }
        guard let prepared = dedup.prepare(sanitized, now: now) else { return }
        logger.debug("Snapshot: \(prepared.title ?? "-", privacy: .public) isPlaying=\(isPlaying, privacy: .public) rawRate=\(rawRate ?? .nan) rate=\(prepared.playbackRate) artwork=\(prepared.artworkData?.count ?? 0)B")
        sendSnapshot?(prepared)
    }

    /// Dates the transport flips this publish represents. Called before the snapshot is built, so
    /// the flip that a stale info pair has to be measured against is already recorded.
    private func recordTransportFlip(isPlaying: Bool, at now: Date) {
        defer { lastIsPlaying = isPlaying }
        guard let was = lastIsPlaying, was != isPlaying else { return }
        if isPlaying {
            resumeObservedAt = now
            pauseObservedAt = nil
        } else {
            pauseObservedAt = now
            resumeObservedAt = nil
        }
    }

    /// Replaces an `elapsed`/`timestamp` pair that predates the current play/pause flip with the
    /// position the last published snapshot projects to at the moment of that flip.
    ///
    /// Pausing at 1:00 a track whose info pair still says "0:45 at T0" would otherwise publish
    /// 0:45 with rate 0, and the UI would snap backwards by the 15 s that had been projected. A
    /// pair stamped *after* the flip is a genuine update from the source and is trusted as-is.
    private func rebaseOnFlipIfPairIsStale(_ snapshot: inout NowPlayingSnapshot, isPlaying: Bool) {
        guard let flippedAt = isPlaying ? resumeObservedAt : pauseObservedAt,
              snapshot.timestamp < flippedAt,
              let last = lastPublished,
              Self.isSameTrack(last, snapshot),
              let frozen = PlaybackProgressTracker.elapsed(for: last, at: flippedAt)
        else { return }
        let reported = snapshot.elapsed ?? .nan
        logger.debug("Stale MediaRemote pair on \(isPlaying ? "resume" : "pause", privacy: .public): elapsed \(reported) → \(frozen)")
        snapshot.elapsed = frozen
        snapshot.timestamp = flippedAt
    }

    /// A frozen position only carries over within one track; across a track change the info pair,
    /// stale or not, is the only thing that describes the new track.
    private static func isSameTrack(_ a: NowPlayingSnapshot, _ b: NowPlayingSnapshot) -> Bool {
        a.title == b.title && a.artist == b.artist && a.artworkID == b.artworkID
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
