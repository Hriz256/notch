import SwiftUI

@main
struct NotchApp: App {
    var body: some Scene {
        MenuBarExtra("Notch", systemImage: "rectangle.topthird.inset.filled") {
            Button("Quit Notch") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
