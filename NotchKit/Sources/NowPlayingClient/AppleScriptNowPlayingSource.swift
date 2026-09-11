import Foundation
import os
import NowPlayingShared

/// Polls Spotify / Music through AppleScript every `interval` while one of them runs.
public final class AppleScriptNowPlayingSource: NowPlayingSource, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    public let name = "applescript"
    static let spotify = "com.spotify.client"
    static let music = "com.apple.Music"

    private let logger = Logger(subsystem: "app.notch", category: "nowplaying.applescript")
    private let lock = NSLock()
    private let interval: Duration
    private var continuation: AsyncStream<NowPlayingEvent>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var artworkCache: (url: String, data: Data)?

    public init(interval: Duration = .seconds(2)) {
        self.interval = interval
    }

    public func events() -> AsyncStream<NowPlayingEvent> {
        AsyncStream { c in self.lock.withLock { self.continuation = c } }
    }

    public func start() async {
        let interval = self.interval
        lock.withLock {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.poll()
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func stop() async {
        lock.withLock {
            pollTask?.cancel()
            pollTask = nil
            continuation?.finish()
            continuation = nil
        }
    }

    public func send(_ command: PlaybackCommand) async {
        guard let app = activeApp() else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .seek(let s): verb = "set player position to \(s)"
        }
        _ = await AppleScriptRunner.run("tell application id \"\(app)\" to \(verb)")
        await poll()
    }

    /// True when Spotify or Music is running and its player state is playing.
    public static func isAnythingPlaying() async -> Bool {
        for app in [spotify, music] where AppleScriptRunner.isRunning(bundleID: app) {
            let out = await AppleScriptRunner.run("tell application id \"\(app)\" to return player state as string")
            if out == "playing" { return true }
        }
        return false
    }

    // MARK: Private

    private func activeApp() -> String? {
        [Self.spotify, Self.music].first { AppleScriptRunner.isRunning(bundleID: $0) }
    }

    private func poll() async {
        guard let app = activeApp() else { return }
        let script = """
        tell application id "\(app)"
            if player state is stopped then return "stopped"
            set t to current track
            set st to player state as string
            set artURL to ""
            \(app == Self.spotify ? "set artURL to artwork url of t" : "")
            return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position) & linefeed & st & linefeed & artURL & linefeed & (id of t as string)
        end tell
        """
        guard let out = await AppleScriptRunner.run(script), out != "stopped" else { return }
        let f = out.components(separatedBy: "\n")
        guard f.count >= 8 else {
            logger.debug("Unexpected AppleScript field count: \(f.count, privacy: .public)")
            return
        }
        // Spotify duration is milliseconds, Music duration is seconds.
        let rawDuration = Double(f[3]) ?? 0
        let duration = app == Self.spotify ? rawDuration / 1000 : rawDuration
        let artwork = await artworkData(url: f[6])
        let snapshot = NowPlayingSnapshot(
            title: f[0], artist: f[1], album: f[2],
            artworkData: artwork, artworkID: f[6].isEmpty ? f[7] : f[6],
            duration: duration, elapsed: Double(f[4]),
            playbackRate: f[5] == "playing" ? 1 : 0,
            sourceBundleID: app, timestamp: Date()
        )
        lock.withLock { continuation }?.yield(.snapshot(snapshot))
    }

    private func artworkData(url: String) async -> Data? {
        guard !url.isEmpty, let u = URL(string: url) else { return nil }
        if let cached = lock.withLock({ artworkCache }), cached.url == url { return cached.data }
        guard let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
        lock.withLock { artworkCache = (url, data) }
        return data
    }
}
