import Foundation

/// Thin dlopen/dlsym wrapper around the private MediaRemote framework.
/// No headers are used; every function is resolved by name at runtime.
///
/// `MRMediaRemoteGetNowPlayingClient` and `MRNowPlayingClientGetBundleIdentifier` are absent on
/// some macOS builds, so they are optional: when either is missing the bridge still loads and the
/// monitor reports `sourceBundleID == nil`. Every other symbol is required — without it there is
/// nothing useful to publish — and a miss makes `init?` fail so the helper can tell the app.
final class MediaRemoteBridge: @unchecked Sendable {
    // @unchecked: wraps an immutable dlopen handle and C function pointers, which are thread-safe.

    typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias GetClientFn = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    typealias ClientBundleIDFn = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
    typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    typealias SetElapsedFn = @convention(c) (Double) -> Void

    enum Command: Int32 {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, nextTrack = 4, previousTrack = 5
    }

    static let infoDidChange = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let isPlayingDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
    static let applicationDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")

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
    /// nil when the symbol is missing on this macOS build; the source bundle id is then unknown.
    let getClient: GetClientFn?
    /// nil when the symbol is missing on this macOS build; see `getClient`.
    let clientBundleID: ClientBundleIDFn?
    let sendCommand: SendCommandFn
    let setElapsed: SetElapsedFn

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
    }

    deinit { dlclose(handle) }
}
