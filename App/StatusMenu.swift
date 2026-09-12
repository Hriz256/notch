import SwiftUI
import CodeAgentFeature
import CodeAgentShared
import IslandCore
import MusicFeature

struct StatusMenu: View {
    @Bindable var coordinator: AppCoordinator
    @AppStorage(MusicViewModel.trackChangePeekDefaultsKey) private var trackChangePeek = true

    var body: some View {
        ForEach(coordinator.registry.features, id: \.id) { feature in
            Toggle(feature.id.rawValue.capitalized, isOn: Binding(
                get: { coordinator.registry.isEnabled(feature.id) },
                set: { coordinator.registry.setEnabled(feature.id, $0) }
            ))
        }
        Toggle("Track change peek", isOn: $trackChangePeek)
        Divider()
        cards
        codingAgents
        Divider()
        // Reloading is a no-op while music is off, so the button reflects that rather than looking
        // like it did something.
        Button("Reload helper") { coordinator.reloadMusic() }
            .disabled(!coordinator.registry.isEnabled(MusicViewModel.featureID))
        Divider()
        #if DEBUG
        Button("Toggle demo island") { coordinator.toggleDemo() }
        Divider()
        #endif
        Button("Quit Notch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The same card list the island's own menu shows, reachable when the pointer is
    /// nowhere near the notch — or when nothing is on screen to right-click at all.
    private var cards: some View {
        Menu("Cards") {
            CardsMenuSection(presenter: coordinator.presenter, includesHeader: false)
        }
    }

    /// Mirrors the island's context menu for the settings that are worth changing without
    /// waiting for a card to be on screen — above all, which agents are watched at all.
    private var codingAgents: some View {
        Menu("Coding agents") {
            ForEach(Agent.allCases, id: \.self) { agent in
                Toggle(agent.displayName, isOn: Binding(
                    get: { coordinator.codeFeature.isAgentEnabled(agent) },
                    set: { coordinator.codeFeature.setAgentEnabled(agent, $0) }
                ))
            }
            // Per-agent stage filters. Nested one level down because there are four of them
            // per agent, and the top level has to stay readable at a glance.
            if !coordinator.codeFeature.settings.enabledAgents.isEmpty {
                Divider()
                ForEach(coordinator.codeFeature.settings.enabledAgents, id: \.self) { agent in
                    Menu(agent.displayName) {
                        ForEach(CodeSettings.filterableStages, id: \.self) { stage in
                            Toggle(CodeAgentViewModel.stageMenuTitle(stage), isOn: Binding(
                                get: { coordinator.codeFeature.showsStage(agent, stage) },
                                set: { coordinator.codeFeature.setShowsStage(agent, stage, $0) }
                            ))
                        }
                        Divider()
                        Toggle("Show when idle", isOn: Binding(
                            get: { coordinator.codeFeature.showWhenIdle(agent) },
                            set: { coordinator.codeFeature.setShowWhenIdle(agent, $0) }
                        ))
                    }
                }
            }
            Divider()
            Toggle("Play completion sound", isOn: Binding(
                get: { coordinator.codeFeature.settings.playCompleteSound },
                set: { coordinator.codeFeature.settings.playCompleteSound = $0 }
            ))
            Toggle("Show pace indicator", isOn: Binding(
                get: { coordinator.codeFeature.settings.showPace },
                set: { coordinator.codeFeature.settings.showPace = $0 }
            ))
            Toggle("Caffeinate while working", isOn: Binding(
                get: { coordinator.codeFeature.settings.caffeinate },
                set: { coordinator.codeFeature.settings.caffeinate = $0 }
            ))
            // Codex silently ignores its `[hooks]` table until the user approves it, so the
            // island would simply never show Codex activity with no explanation.
            if coordinator.codeFeature.codexNeedsTrust {
                Divider()
                Button("Codex: run /hooks to approve") {}
                    .disabled(true)
            }
        }
    }
}
