import Foundation

public enum NowPlayingXPC {
    /// Must start with `com.apple.controlcenter.` for MediaRemote to answer on macOS 15.4+.
    public static let serviceName = "com.apple.controlcenter.NotchHelper"
}

/// Commands the app sends to the helper.
@objc public protocol NowPlayingHelperProtocol {
    func startMonitoring()
    func requestFullState()
    func play()
    func pause()
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(toSeconds seconds: Double)
}

/// Callbacks the helper sends to the app. Payload is `NowPlayingSnapshot.encoded()`.
@objc public protocol NowPlayingHelperClientProtocol {
    func snapshotDidChange(_ data: Data)
    func helperUnavailable(_ reason: String)
}
