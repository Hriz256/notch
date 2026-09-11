import Testing
import Foundation
import CodeAgentShared
@testable import CodeAgentFeature

@MainActor
final class CodeSettingsTests {
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        suite = "app.notch.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test func defaultsFollowTheSpec() {
        let settings = CodeSettings(defaults: defaults, installedAgents: [.claude, .codex])

        #expect(settings.isEnabled(.claude))
        #expect(settings.isEnabled(.codex))
        #expect(!settings.isEnabled(.cursor))
        for stage in CodeSettings.filterableStages {
            #expect(settings.showsStage(.claude, stage))
        }
        #expect(settings.showsStage(.claude, .waiting))  // not filterable
        #expect(settings.showWhenIdle(.claude))
        #expect(settings.playCompleteSound)
        #expect(settings.showPace)
        #expect(!settings.caffeinate)
        #expect(settings.currentAgent == .claude)
    }

    @Test func writesUseTheSpecKeys() {
        let settings = CodeSettings(defaults: defaults, installedAgents: [])
        settings.setEnabled(.cursor, true)
        settings.setShowsStage(.codex, .thinking, false)
        settings.setShowWhenIdle(.claude, false)
        settings.caffeinate = true
        settings.currentAgent = .codex

        #expect(defaults.bool(forKey: "code.cursor.enabled"))
        #expect(defaults.object(forKey: "code.codex.showThinking") as? Bool == false)
        #expect(defaults.object(forKey: "code.claude.showWhenIdle") as? Bool == false)
        #expect(defaults.bool(forKey: "code.caffeinate"))
        #expect(defaults.string(forKey: "code.currentAgent") == "codex")
        #expect(settings.enabledAgents == [.claude, .cursor])
    }

    @Test func firstLaunchDecisionSurvivesALaterInstall() {
        _ = CodeSettings(defaults: defaults, installedAgents: [.claude])
        // Codex shows up later; its switch must stay off.
        let second = CodeSettings(defaults: defaults, installedAgents: [.claude, .codex])
        #expect(!second.isEnabled(.codex))
    }

    @Test func explicitChoicesArePersisted() {
        let first = CodeSettings(defaults: defaults, installedAgents: [.claude, .codex])
        first.setEnabled(.codex, false)
        first.setShowsStage(.claude, .analyzing, false)
        first.playCompleteSound = false

        let second = CodeSettings(defaults: defaults, installedAgents: [.claude, .codex])
        #expect(!second.isEnabled(.codex))
        #expect(!second.showsStage(.claude, .analyzing))
        #expect(second.showsStage(.claude, .creating))
        #expect(!second.playCompleteSound)
    }

    @Test func detectionUsesTheAgentDirectories() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // The probes also look at machine-wide paths (`/Applications/Cursor.app`,
        // `/opt/homebrew/bin/codex`), so only the positive direction is asserted here.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let found = CodeSettings.detectInstalledAgents(home: home)
        #expect(found.contains(.codex))
        #expect(found.contains(.claude))
    }
}
