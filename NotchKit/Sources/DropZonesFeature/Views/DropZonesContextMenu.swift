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
    /// The file the menu was opened on, when it was opened on one tile of the expanded
    /// row. That tile gets a row of its own for taking just that file out — the counterpart
    /// to dragging it out, for when the user wants it gone rather than somewhere else.
    var file: StashedFile?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let file {
                // Through the poof rather than straight to `removeFile`, so the tile is seen
                // to leave — the row closing up on its own reads as a glitch.
                Button("Remove \(file.name)") { model.poofFile(id: file.id) }

                Divider()
            }

            // Then the cards, so switching card is in the same place wherever the user
            // right-clicks.
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
    ///
    /// - Parameter file: the one file this part of the island stands for, if any; it adds a
    ///   "Remove <name>" row at the top.
    func dropZonesContextMenu(_ model: DropZonesViewModel, removing file: StashedFile? = nil) -> some View {
        modifier(DropZonesContextMenu(model: model, file: file))
    }
}
