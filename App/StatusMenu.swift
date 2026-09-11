import SwiftUI
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
        Button("Reload helper") { coordinator.reloadMusic() }
        Divider()
        #if DEBUG
        Button("Toggle demo island") { coordinator.toggleDemo() }
        Divider()
        #endif
        Button("Quit Notch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
