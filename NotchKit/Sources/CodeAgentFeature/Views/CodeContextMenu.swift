import CodeAgentShared
import IslandCore
import SwiftUI

/// The right-click menu carried by every part of the Code island — both peek slots and
/// both expanded panels.
///
/// It is the feature's only in-island settings surface: the island has no chrome to hang
/// buttons off, so switching agent, silencing the chime and repairing hooks all live here.
/// `Toggle` is deliberately not used: inside a `contextMenu` it renders without a visible
/// state on some macOS versions, whereas an explicit checkmark label always reads.
struct CodeContextMenu: ViewModifier {
    let model: CodeAgentViewModel

    func body(content: Content) -> some View {
        content.contextMenu {
            // First, so switching card is in the same place wherever the user right-clicks
            // — the feature's content here, the black shape in `SurfaceView`.
            CardsMenuSection(presenter: model.islandPresenter)

            Divider()

            Section("Show") {
                ForEach(model.enabledAgents, id: \.self) { agent in
                    checkmarked(agent.displayName, isOn: agent == model.displayedAgent) {
                        model.selectAgent(agent)
                    }
                }
            }

            Divider()

            checkmarked("Caffeinate agent", isOn: model.caffeinateWhileWorking) {
                model.toggleCaffeinate()
            }
            checkmarked("Play completion sound", isOn: model.playsCompletionSound) {
                model.togglePlayCompletionSound()
            }
            Button("Refresh usage") { model.refreshUsage() }

            ForEach(model.enabledAgents, id: \.self) { agent in
                Divider()
                // One submenu per agent: which stages that agent may show, and whether it
                // keeps a card up when nothing is running.
                Menu(agent.displayName) {
                    ForEach(CodeSettings.filterableStages, id: \.self) { stage in
                        checkmarked(
                            CodeAgentViewModel.stageMenuTitle(stage),
                            isOn: model.showsStage(agent, stage)
                        ) {
                            model.toggleStage(agent, stage)
                        }
                    }
                    Divider()
                    checkmarked("Show when idle", isOn: model.showsWhenIdle(agent)) {
                        model.toggleShowWhenIdle(agent)
                    }
                }
                Section(Self.hookTitle(agent, model.hookStates[agent])) {
                    Button("Install hooks") { model.setHooksInstalled(agent, true) }
                    Button("Remove hooks") { model.setHooksInstalled(agent, false) }
                }
            }
        }
    }

    /// A menu row that shows its state as a leading checkmark.
    @ViewBuilder
    private func checkmarked(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// `"Claude Code — Hooks: Installed"`, or the reason the config could not be edited,
    /// which is the only place the user ever sees it.
    static func hookTitle(_ agent: Agent, _ state: HookInstaller.InstallState?) -> String {
        switch state ?? .notInstalled {
        case .installed: "\(agent.displayName) — Hooks: Installed"
        case .notInstalled: "\(agent.displayName) — Hooks: Not installed"
        case .failed(let reason): "\(agent.displayName) — \(reason)"
        }
    }
}

extension View {
    /// Attaches the Code island's context menu.
    func codeContextMenu(_ model: CodeAgentViewModel) -> some View {
        modifier(CodeContextMenu(model: model))
    }
}
