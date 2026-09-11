import Testing
import Foundation
import CodeAgentShared
@testable import CodeAgentFeature

/// The distributed notification itself is exercised by the `notch-hook` smoke test;
/// here only the parsing seam is driven, so no system-wide notification is posted.
@MainActor
struct EventReceiverTests {

    private func make() -> (EventReceiver, Box) {
        let box = Box()
        let receiver = EventReceiver { box.events.append($0) }
        return (receiver, box)
    }

    @MainActor final class Box {
        var events: [AgentEvent] = []
    }

    @Test func mapsAValidPayload() {
        let (receiver, box) = make()
        receiver.receive(
            agent: "claude",
            payload: #"{"hook_event_name": "PreToolUse", "tool_name": "Edit", "session_id": "abc"}"#)

        #expect(box.events.count == 1)
        #expect(box.events.first?.agent == .claude)
        #expect(box.events.first?.stage == .creating)
        #expect(box.events.first?.tool == "Edit")
        #expect(box.events.first?.sessionID == "abc")
    }

    @Test func ignoresMalformedInput() {
        let (receiver, box) = make()
        receiver.receive(agent: nil, payload: #"{"hook_event_name": "Stop"}"#)
        receiver.receive(agent: "gemini", payload: #"{"hook_event_name": "Stop"}"#)
        receiver.receive(agent: "claude", payload: nil)
        receiver.receive(agent: "claude", payload: "")
        receiver.receive(agent: "claude", payload: "not json")
        receiver.receive(agent: "claude", payload: "[1, 2]")           // not an object
        receiver.receive(agent: "claude", payload: #"{"hook_event_name": "PreCompact"}"#)  // ignored event

        #expect(box.events.isEmpty)
    }

    @Test func stopAndStartAreIdempotent() {
        let (receiver, _) = make()
        receiver.stop()
        receiver.start()
        receiver.start()
        receiver.stop()
    }
}
