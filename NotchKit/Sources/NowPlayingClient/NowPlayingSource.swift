import Foundation
import NowPlayingShared

public enum NowPlayingEvent: Sendable, Equatable {
    case snapshot(NowPlayingSnapshot)
    case unavailable(String)
}

public enum PlaybackCommand: Sendable, Equatable {
    case play, pause, togglePlayPause, next, previous
    case seek(TimeInterval)
}

/// A producer of now-playing events. `events()` may be called once per start: a second call
/// replaces the source's continuation, so the previously returned stream stops receiving events.
public protocol NowPlayingSource: AnyObject, Sendable {
    var name: String { get }
    func events() -> AsyncStream<NowPlayingEvent>
    func start() async
    func stop() async
    func send(_ command: PlaybackCommand) async
}
