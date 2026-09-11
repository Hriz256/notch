import Testing
import Foundation
@testable import CodeAgentShared

@Suite struct AgentTests {
    @Test func coversThreeAgents() {
        #expect(Agent.allCases.count == 3)
        #expect(Agent.allCases.map(\.rawValue) == ["claude", "codex", "cursor"])
    }

    @Test func displayNames() {
        #expect(Agent.claude.displayName == "Claude Code")
        #expect(Agent.codex.displayName == "Codex")
        #expect(Agent.cursor.displayName == "Cursor")
    }

    @Test func eventRoundTripsThroughJSON() throws {
        let event = AgentEvent(
            agent: .claude,
            sessionID: "abc",
            stage: .creating,
            tool: "Edit",
            detail: "editing main.swift",
            sourceApp: "iTerm.app",
            timestamp: Date(timeIntervalSince1970: 1_757_000_000)
        )
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(AgentEvent.self, from: data) == event)
    }
}
