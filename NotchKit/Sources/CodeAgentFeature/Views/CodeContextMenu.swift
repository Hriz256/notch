import CodeAgentShared
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
