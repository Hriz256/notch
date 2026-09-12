import AppKit
import IslandCore
import SwiftUI

/// The right-click menu carried by the Music island — both peek slots and the expanded panel.
///
/// Music has no settings of its own to hang here; the menu exists so the card switcher is
/// reachable from wherever the user right-clicks. A right-click opens exactly one menu (the
/// innermost `.contextMenu` under the pointer), so content that carries none would hide the
/// island's own menu on `NotchShape` behind it.
struct MusicContextMenu: ViewModifier {
    let model: MusicViewModel

    func body(content: Content) -> some View {
        content.contextMenu {
            CardsMenuSection(presenter: model.islandPresenter)

            if let app = MusicSourceApp(bundleID: model.snapshot?.sourceBundleID) {
                Divider()
                Button("Open in \(app.name)") { app.open() }
            }
        }
    }
}

/// The app the current track is playing in, resolved from its bundle id.
///
/// Shared by the menu row and the artwork tap in ``MusicExpandedView`` so both open the
/// same thing.
struct MusicSourceApp {
    let url: URL

    var name: String {
        FileManager.default.displayName(atPath: url.path)
    }

    init?(bundleID: String?) {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        self.url = url
    }

    @MainActor
    func open() {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension View {
    /// Attaches the Music island's context menu.
    func musicContextMenu(_ model: MusicViewModel) -> some View {
        modifier(MusicContextMenu(model: model))
    }
}
