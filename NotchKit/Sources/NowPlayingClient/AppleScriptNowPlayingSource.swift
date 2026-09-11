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
        guard let app = await activeApp() else { return }
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
        await playingApp() != nil
    }

    // MARK: Private

    /// The running app whose player state is `playing`, if any.
    private static func playingApp() async -> String? {
        for app in runningApps() where await playerState(of: app) == "playing" { return app }
        return nil
    }

    private static func runningApps() -> [String] {
        [spotify, music].filter { AppleScriptRunner.isRunning(bundleID: $0) }
    }

    private static func playerState(of app: String) async -> String? {
        await AppleScriptRunner.run("tell application id \"\(app)\" to return player state as string")
    }

    /// The app to read from and send commands to: whichever running app is actually playing,
    /// falling back to the first running one (so a paused player is still controllable).
    private func activeApp() async -> String? {
        if let playing = await Self.playingApp() { return playing }
        return Self.runningApps().first
    }

    private func poll() async {
        guard let app = await activeApp() else { return }
        // Both numbers are emitted as integer milliseconds: `round` yields an integer whose text
        // form has no decimal separator, so parsing stays correct in comma-decimal locales.
        // Spotify's `duration` is already milliseconds; Music's is seconds.
        let durationMS = app == Self.spotify ? "(round (duration of t))" : "(round ((duration of t) * 1000))"
        let script = """
        tell application id "\(app)"
            if player state is stopped then return "stopped"
            set t to current track
            set st to player state as string
            set artURL to ""
            \(app == Self.spotify ? "set artURL to artwork url of t" : "")
            return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & \(durationMS) & linefeed & (round ((player position) * 1000)) & linefeed & st & linefeed & artURL & linefeed & (id of t as string)
        end tell
        """
        guard let out = await AppleScriptRunner.run(script), out != "stopped" else { return }
        let fields = out.components(separatedBy: "\n")
        guard var snapshot = Self.parseSnapshot(fields: fields, app: app, now: Date()) else {
            logger.debug("Unexpected AppleScript field count: \(fields.count, privacy: .public)")
            return
        }
        snapshot.artworkData = await artworkData(url: fields[6])
        lock.withLock { continuation }?.yield(.snapshot(snapshot))
    }

    /// Builds a snapshot (without artwork bytes) from the script's newline-separated output:
    /// title, artist, album, duration ms, position ms, player state, artwork URL, track id.
    static func parseSnapshot(fields: [String], app: String, now: Date) -> NowPlayingSnapshot? {
        guard fields.count >= 8 else { return nil }
        let artworkURL = fields[6]
        return NowPlayingSnapshot(
            title: fields[0], artist: fields[1], album: fields[2],
            artworkData: nil, artworkID: artworkURL.isEmpty ? fields[7] : artworkURL,
            duration: seconds(fromMilliseconds: fields[3]),
            elapsed: seconds(fromMilliseconds: fields[4]),
            playbackRate: fields[5] == "playing" ? 1 : 0,
            sourceBundleID: app, timestamp: now
        )
    }

    /// nil rather than 0 when the field is not an integer: an absent duration beats a wrong one.
    private static func seconds(fromMilliseconds text: String) -> TimeInterval? {
        guard let ms = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return TimeInterval(ms) / 1000
    }

    private func artworkData(url: String) async -> Data? {
        guard !url.isEmpty, let u = URL(string: url) else { return nil }
        if let cached = lock.withLock({ artworkCache }), cached.url == url { return cached.data }
        guard let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
        lock.withLock { artworkCache = (url, data) }
        return data
    }
}
