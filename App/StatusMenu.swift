import SwiftUI
import IslandCore

struct StatusMenu: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        ForEach(coordinator.registry.features, id: \.id) { feature in
            Toggle(feature.id.rawValue.capitalized, isOn: Binding(
                get: { coordinator.registry.isEnabled(feature.id) },
                set: { coordinator.registry.setEnabled(feature.id, $0) }
            ))
        }
        if !coordinator.registry.features.isEmpty { Divider() }
        #if DEBUG
        Button("Toggle demo island") { coordinator.toggleDemo() }
        Divider()
        #endif
        Button("Quit Notch") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
