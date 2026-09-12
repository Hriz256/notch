import DropZonesShared
import IslandCore
import SwiftUI

/// The right-click menu carried by every part of the Drop Zones island — both peek slots,
/// the hover-expanded stash card and the zones panel.
///
/// Together with the status-menu submenu it is the feature's only settings surface, and it
/// is the one the user can reach while looking at the thing they want to change. `Toggle`
/// is deliberately not used, for the same reason as in `CodeContextMenu`: inside a
/// `contextMenu` it renders without a visible state on some macOS versions, whereas an
/// explicit checkmark label always reads.
struct DropZonesContextMenu: ViewModifier {
    let model: DropZonesViewModel

    func body(content: Content) -> some View {
        content.contextMenu {
            // First, so switching card is in the same place wherever the user right-clicks.
            CardsMenuSection(presenter: model.islandPresenter)

            Divider()

            checkmarked("AirDrop zone", isOn: model.settings.airdrop) { model.toggleAirDrop() }
            checkmarked("File Stash zone", isOn: model.settings.stash) { model.toggleStashZone() }
            checkmarked("Offer the other action as a third zone", isOn: model.settings.secondZone) {
                model.toggleSecondZone()
            }

            Section("When stash has files") {
                checkmarked("Replace", isOn: model.settings.stashDropAction == .replace) {
                    model.setStashDropAction(.replace)
                }
                checkmarked("Add", isOn: model.settings.stashDropAction == .add) {
                    model.setStashDropAction(.add)
                }
            }

            Divider()

            Button("Reveal stash in Finder") { model.revealStash() }
            Button("Clear stash") {
                Task { await model.clearStash() }
            }
            // Nothing to clear is not an error worth a beep: the row simply greys out, and
            // its state doubles as an answer to "is there anything in there?".
            .disabled(model.index.files.isEmpty)
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
}

extension View {
    /// Attaches the Drop Zones island's context menu.
    func dropZonesContextMenu(_ model: DropZonesViewModel) -> some View {
        modifier(DropZonesContextMenu(model: model))
    }
}
