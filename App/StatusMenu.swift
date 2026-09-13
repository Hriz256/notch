import SwiftUI
import CodeAgentFeature
import CodeAgentShared
import DropZonesFeature
import DropZonesShared
import HUDFeature
import IslandCore
import MusicFeature

struct StatusMenu: View {
    @Bindable var coordinator: AppCoordinator
    @AppStorage(MusicViewModel.trackChangePeekDefaultsKey) private var trackChangePeek = true
    @AppStorage(MusicViewModel.keepPausedTrackDefaultsKey) private var keepPausedTrack = true

    var body: some View {
        ForEach(coordinator.registry.features, id: \.id) { feature in
            Toggle(Self.title(for: feature.id), isOn: Binding(
                get: { coordinator.registry.isEnabled(feature.id) },
                set: { coordinator.registry.setEnabled(feature.id, $0) }
            ))
        }
        Toggle("Track change peek", isOn: $trackChangePeek)
        Toggle("Keep paused track", isOn: $keepPausedTrack)
        Divider()
        cards
        codingAgents
        dropZones
        hud
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

    /// The master-switch row's label. `capitalized` on the raw id reads correctly for
    /// "music" and "code"; the ids that stand for more than one word are spelled out.
    private static func title(for id: FeatureID) -> String {
        switch id {
        case DropZonesViewModel.featureID: DropZonesViewModel.displayTitle
        case HUDViewModel.featureID: "Volume & Brightness HUD"
        default: id.rawValue.capitalized
        }
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

    /// Mirrors the island's Drop Zones context menu. The zones panel is only ever on screen
    /// during a drag, so this is the one place those settings can actually be reached with
    /// the pointer — the context menu on the panel would need a third hand.
    private var dropZones: some View {
        Menu(DropZonesViewModel.displayTitle) {
            Toggle("AirDrop zone", isOn: Binding(
                get: { coordinator.dropZonesFeature.settings.airdrop },
                set: { coordinator.dropZonesFeature.setAirDropZone($0) }
            ))
            Toggle("File Stash zone", isOn: Binding(
                get: { coordinator.dropZonesFeature.settings.stash },
                set: { coordinator.dropZonesFeature.setStashZone($0) }
            ))
            Toggle("Offer the other action as a third zone", isOn: Binding(
                get: { coordinator.dropZonesFeature.settings.secondZone },
                set: { coordinator.dropZonesFeature.setSecondZone($0) }
            ))
            Picker("When stash has files", selection: Binding(
                get: { coordinator.dropZonesFeature.settings.stashDropAction },
                set: { coordinator.dropZonesFeature.setStashDropAction($0) }
            )) {
                Text("Replace").tag(StashDropAction.replace)
                Text("Add").tag(StashDropAction.add)
            }
            Divider()
            // Both rows need a live view model; "Clear stash" additionally needs something
            // to clear, and its greyed-out state doubles as "there is nothing in there".
            Button("Reveal stash in Finder") { coordinator.dropZonesFeature.revealStash() }
                .disabled(coordinator.dropZonesFeature.model == nil)
            Button("Clear stash") { coordinator.dropZonesFeature.clearStash() }
                .disabled(coordinator.dropZonesFeature.stashIsEmpty)
        }
        // Switched off, none of this has any effect until the feature comes back.
        .disabled(!coordinator.registry.isEnabled(DropZonesViewModel.featureID))
    }

    /// Which levels show a HUD. Both off leaves the system HUD alone.
    private var hud: some View {
        Menu("HUD") {
            Toggle("Volume", isOn: Binding(
                get: { coordinator.hudFeature.settings.volume },
                set: { coordinator.hudFeature.setVolume($0) }
            ))
            Toggle("Brightness", isOn: Binding(
                get: { coordinator.hudFeature.settings.brightness },
                set: { coordinator.hudFeature.setBrightness($0) }
            ))
        }
        .disabled(!coordinator.registry.isEnabled(HUDViewModel.featureID))
    }
}
