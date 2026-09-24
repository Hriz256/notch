import Foundation

/// Thin dlopen/dlsym wrapper around the private MediaRemote framework.
/// No headers are used; every function is resolved by name at runtime.
///
/// Required: the notification registration and the calls on macOS's *elected* now-playing player
/// (its info, its is-playing flag, `MRMediaRemoteSendCommand`, `MRMediaRemoteSetElapsedTime`).
/// Without any of them there is nothing useful to publish, and a miss makes `init?` fail so the
/// helper can tell the app.
///
/// Optional, because they are absent on some macOS builds or private beyond the rest:
/// - `perClient`, the calls that address one listed player rather than the elected one, and
///   `MRNowPlayingClientGetBundleIdentifier`, which player ids are built from: without any of
///   them the monitor follows the elected player, as it did before it could tell players apart,
///   and without the bundle-id call it also reports `sourceBundleID == nil`.
/// - `MRMediaRemoteGetNowPlayingClient`, macOS's elected client: while following players it only
///   breaks ties, and without it ties go by start time and list order; while following the
///   elected player it names the source app, and without it `sourceBundleID` is nil.
/// - `MRNowPlayingClientGetProcessIdentifier`: names a player that has no bundle id, tells two
///   processes of one app apart, and matches the elected client to its list entry. Without it
///   those go by list order, and the elected client matches its app's first entry.
final class MediaRemoteBridge: @unchecked Sendable {
    // @unchecked: wraps an immutable dlopen handle and C function pointers, which are thread-safe.

    typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias GetClientFn = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    typealias ClientBundleIDFn = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
    typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    typealias SetElapsedFn = @convention(c) (Double) -> Void

    // The per-client signatures below come from `spikes/MediaRemoteSpike`, which recovered them
    // with `dyld_info -disassemble` and called each one successfully on macOS 26.5 (spec §3 of
    // docs/superpowers/specs/2026-09-24-music-player-choice-design.md). A guessed signature crashes.

    /// Returns the local `MROrigin` unretained: MediaRemote owns it.
    typealias GetLocalOriginFn = @convention(c) () -> Unmanaged<AnyObject>?
    /// Replies with an `NSArray` of `MRClient`, one per now-playing app, elected or not.
    typealias GetClientsFn = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    /// (client, origin, queue, reply). The reply takes the state alone: declaring a second
    /// parameter reads garbage and crashes.
    typealias StateForClientFn = @convention(c) (AnyObject?, AnyObject?, DispatchQueue, @escaping @convention(block) (UInt32) -> Void) -> Void
    /// (client, origin, withArtwork, queue, reply).
    typealias InfoForClientFn = @convention(c) (AnyObject?, AnyObject?, Bool, DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    /// (command, options, origin, client, appOptions, queue, completion). The result is always 1,
    /// whatever the player does (`mov w0, #0x1` before its only `retab`), so it reports nothing.
    typealias SendToClientFn = @convention(c) (UInt32, CFDictionary?, AnyObject?, AnyObject?, UInt32, DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Bool
    typealias ClientPIDFn = @convention(c) (AnyObject?) -> Int32

    /// The calls that address one listed player instead of the elected one, so the island can
    /// follow the player you hear and send its buttons there. Grouped because the monitor needs
    /// all five or none: one optional to test, not five.
    struct PerClient {
        /// `MRMediaRemoteGetLocalOrigin`
        let getLocalOrigin: GetLocalOriginFn
        /// `MRMediaRemoteGetNowPlayingClients`
        let getClients: GetClientsFn
        /// `MRMediaRemoteGetPlaybackStateForClient`
        let getPlaybackState: StateForClientFn
        /// `MRMediaRemoteGetNowPlayingInfoForClient`
        let getInfo: InfoForClientFn
        /// `MRMediaRemoteSendCommandToClient`
        let sendCommand: SendToClientFn
    }

    enum Command: Int32 {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
        /// Takes `playbackPositionOption`; sent through `PerClient.sendCommand` only.
        case seekToPlaybackPosition = 24
    }

    /// The seek target of `Command.seekToPlaybackPosition`, in seconds (`Double`).
    static let playbackPositionOption = "kMRMediaRemoteOptionPlaybackPosition"

    /// Values of `PerClient.getPlaybackState`'s reply (the spike saw 2 for paused, 3 for stopped).
    enum PlaybackState {
        static let playing: UInt32 = 1
    }

    static let infoDidChange = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let isPlayingDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
    static let applicationDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
    // Posted for every player, elected or not: while Chrome is elected, a Spotify track change
    // posts only `playerInfoDidChange`, never `infoDidChange`.
    static let playerInfoDidChange = Notification.Name("kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification")
    static let playerIsPlayingDidChange = Notification.Name("kMRMediaRemotePlayerIsPlayingDidChangeNotification")
    static let playerPlaybackStateDidChange = Notification.Name("kMRMediaRemotePlayerPlaybackStateDidChangeNotification")
    static let applicationDidUnregister = Notification.Name("kMRMediaRemoteNowPlayingApplicationDidUnregister")

    enum InfoKey {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
        static let artworkIdentifier = "kMRMediaRemoteNowPlayingInfoArtworkIdentifier"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
    }

    private let handle: UnsafeMutableRawPointer
    let register: RegisterFn
    let getInfo: GetInfoFn
    let getIsPlaying: GetIsPlayingFn
    /// nil when the symbol is missing on this macOS build; see the type's doc for what is lost.
    let getClient: GetClientFn?
    /// nil when the symbol is missing on this macOS build; see the type's doc for what is lost.
    let clientBundleID: ClientBundleIDFn?
    let sendCommand: SendCommandFn
    let setElapsed: SetElapsedFn
    /// nil when any of the five is missing on this macOS build; the monitor then follows the
    /// elected player only.
    let perClient: PerClient?
    /// `MRNowPlayingClientGetProcessIdentifier`; nil when the symbol is missing on this macOS build.
    let clientPID: ClientPIDFn?

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            return nil
        }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: type)
        }
        guard let register = load("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self),
              let getInfo = load("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self),
              let getIsPlaying = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlayingFn.self),
              let sendCommand = load("MRMediaRemoteSendCommand", as: SendCommandFn.self),
              let setElapsed = load("MRMediaRemoteSetElapsedTime", as: SetElapsedFn.self)
        else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.register = register
        self.getInfo = getInfo
        self.getIsPlaying = getIsPlaying
        self.getClient = load("MRMediaRemoteGetNowPlayingClient", as: GetClientFn.self)
        self.clientBundleID = load("MRNowPlayingClientGetBundleIdentifier", as: ClientBundleIDFn.self)
        self.sendCommand = sendCommand
        self.setElapsed = setElapsed
        if let getLocalOrigin = load("MRMediaRemoteGetLocalOrigin", as: GetLocalOriginFn.self),
           let getClients = load("MRMediaRemoteGetNowPlayingClients", as: GetClientsFn.self),
           let getPlaybackState = load("MRMediaRemoteGetPlaybackStateForClient", as: StateForClientFn.self),
           let getClientInfo = load("MRMediaRemoteGetNowPlayingInfoForClient", as: InfoForClientFn.self),
           let sendToClient = load("MRMediaRemoteSendCommandToClient", as: SendToClientFn.self) {
            self.perClient = PerClient(getLocalOrigin: getLocalOrigin, getClients: getClients,
                                       getPlaybackState: getPlaybackState, getInfo: getClientInfo,
                                       sendCommand: sendToClient)
        } else {
            self.perClient = nil
        }
        self.clientPID = load("MRNowPlayingClientGetProcessIdentifier", as: ClientPIDFn.self)
    }

    deinit { dlclose(handle) }
}
