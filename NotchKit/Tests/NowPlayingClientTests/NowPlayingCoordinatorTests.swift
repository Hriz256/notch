import Testing
import Foundation
@testable import NowPlayingClient
import NowPlayingShared

/// Scriptable source: the test pushes events; records commands.
final class FakeSource: NowPlayingSource, @unchecked Sendable {
    // @unchecked: state guarded by `lock`.
    let name: String
    private let lock = NSLock()
    private var continuation: AsyncStream<NowPlayingEvent>.Continuation?
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var commands: [PlaybackCommand] = []

    init(name: String) { self.name = name }

    func events() -> AsyncStream<NowPlayingEvent> {
        AsyncStream { c in lock.withLock { continuation = c } }
    }
    func start() async { lock.withLock { started += 1 } }
    func stop() async { lock.withLock { stopped += 1 } }
    func send(_ command: PlaybackCommand) async { lock.withLock { commands.append(command) } }
    func push(_ event: NowPlayingEvent) { lock.withLock { continuation }?.yield(event) }
}

private func snapshot(_ title: String) -> NowPlayingSnapshot {
    NowPlayingSnapshot(title: title, artist: nil, album: nil, artworkData: nil, artworkID: nil,
                       duration: 10, elapsed: 0, playbackRate: 1, sourceBundleID: nil, timestamp: Date())
}

private func firstEvent(_ stream: AsyncStream<NowPlayingEvent>, timeout: Duration = .seconds(2)) async -> NowPlayingEvent? {
    await withTaskGroup(of: NowPlayingEvent?.self) { group in
        group.addTask { for await e in stream { return e }; return nil }
        group.addTask { try? await Task.sleep(for: timeout); return nil }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

struct NowPlayingCoordinatorTests {
    @Test func usesPrimaryWhenItDelivers() async {
        let primary = FakeSource(name: "xpc"), fallback = FakeSource(name: "applescript")
        let c = NowPlayingCoordinator(primary: primary, fallback: fallback, probe: { true }, silenceTimeout: .seconds(5))
        let stream = await c.events()
        await c.start()
        primary.push(.snapshot(snapshot("A")))
        #expect(await firstEvent(stream)?.withoutTimestamp == NowPlayingEvent.snapshot(snapshot("A")).withoutTimestamp)
        #expect(await c.activeSourceName == "xpc")
        #expect(fallback.started == 0)
        await c.stop()
    }

    @Test func fallsBackWhenPrimaryUnavailable() async {
        let primary = FakeSource(name: "xpc"), fallback = FakeSource(name: "applescript")
        let c = NowPlayingCoordinator(primary: primary, fallback: fallback, probe: { false }, silenceTimeout: .seconds(5))
        let stream = await c.events()
        await c.start()
        primary.push(.unavailable("no symbols"))
        try? await Task.sleep(for: .milliseconds(100))
        fallback.push(.snapshot(snapshot("B")))
        #expect(await firstEvent(stream)?.withoutTimestamp == NowPlayingEvent.snapshot(snapshot("B")).withoutTimestamp)
        #expect(await c.activeSourceName == "applescript")
        #expect(primary.stopped == 1)
        await c.stop()
    }

    @Test func fallsBackAfterSilenceWhenProbeSaysPlaying() async {
        let primary = FakeSource(name: "xpc"), fallback = FakeSource(name: "applescript")
        let c = NowPlayingCoordinator(primary: primary, fallback: fallback, probe: { true }, silenceTimeout: .milliseconds(100))
        _ = await c.events()
        await c.start()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await c.activeSourceName == "applescript")
        await c.stop()
    }

    @Test func staysOnPrimaryAfterSilenceWhenNothingPlays() async {
        let primary = FakeSource(name: "xpc"), fallback = FakeSource(name: "applescript")
        let c = NowPlayingCoordinator(primary: primary, fallback: fallback, probe: { false }, silenceTimeout: .milliseconds(100))
        _ = await c.events()
        await c.start()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await c.activeSourceName == "xpc")
        #expect(fallback.started == 0)
        await c.stop()
    }

    @Test func commandsGoToActiveSource() async {
        let primary = FakeSource(name: "xpc"), fallback = FakeSource(name: "applescript")
        let c = NowPlayingCoordinator(primary: primary, fallback: fallback, probe: { false }, silenceTimeout: .seconds(5))
        _ = await c.events()
        await c.start()
        await c.send(.next)
        #expect(primary.commands == [.next])
        await c.stop()
    }

    /// After the switch the primary may still be emitting (its stop is best-effort);
    /// those events must never reach the consumer.
    @Test func staleSourceEventsAreIgnored() async {
        let primary = FakeSource(name: "xpc"), fallback = FakeSource(name: "applescript")
        let c = NowPlayingCoordinator(primary: primary, fallback: fallback, probe: { false }, silenceTimeout: .seconds(5))
        let stream = await c.events()
        await c.start()
        primary.push(.unavailable("no symbols"))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await c.activeSourceName == "applescript")

        primary.push(.snapshot(snapshot("STALE")))
        try? await Task.sleep(for: .milliseconds(100))
        fallback.push(.snapshot(snapshot("LIVE")))
        // The first event the consumer sees is the fallback's: the stale one was dropped.
        #expect(await firstEvent(stream)?.withoutTimestamp == NowPlayingEvent.snapshot(snapshot("LIVE")).withoutTimestamp)
        await c.stop()
    }

    @Test func commandsGoToFallbackAfterSwitch() async {
        let primary = FakeSource(name: "xpc"), fallback = FakeSource(name: "applescript")
        let c = NowPlayingCoordinator(primary: primary, fallback: fallback, probe: { false }, silenceTimeout: .seconds(5))
        _ = await c.events()
        await c.start()
        primary.push(.unavailable("no symbols"))
        try? await Task.sleep(for: .milliseconds(200))
        await c.send(.pause)
        #expect(fallback.commands == [.pause])
        #expect(primary.commands.isEmpty)
        await c.stop()
    }
}

private extension NowPlayingEvent {
    /// Timestamps differ per construction; compare everything else.
    var withoutTimestamp: NowPlayingEvent {
        if case .snapshot(var s) = self { s.timestamp = Date(timeIntervalSince1970: 0); return .snapshot(s) }
        return self
    }
}
