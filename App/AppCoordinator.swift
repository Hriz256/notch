import SwiftUI
import IslandCore
import MusicFeature

@MainActor
@Observable
final class AppCoordinator {
    let presenter: IslandPresenter
    let registry: FeatureRegistry
    let surface: SurfaceController
    private var demoID: PresentationID?

    init() {
        let presenter = IslandPresenter(clock: TaskClock())
        self.presenter = presenter
        self.registry = FeatureRegistry(presenter: presenter)
        self.surface = SurfaceController(presenter: presenter)
    }

    func start() {
        surface.start()
        registry.register(MusicFeature(), enabledByDefault: true)
    }

    func stop() {
        registry.deactivateAll()
        surface.stop()
    }

    #if DEBUG
    func toggleDemo() {
        if let demoID {
            presenter.dismiss(demoID)
            self.demoID = nil
            return
        }
        let demo = Presentation(
            featureID: FeatureID("demo"),
            priority: .background,
            style: .peek,
            leading: AnyView(RoundedRectangle(cornerRadius: 4).fill(.orange).frame(width: 18, height: 18)),
            trailing: AnyView(Circle().fill(.green).frame(width: 10, height: 10)),
            expanded: AnyView(
                VStack(spacing: 8) {
                    Text("Demo island").font(.headline).foregroundStyle(.white)
                    Text("Hover to expand, move away to collapse").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            ),
            expandedSize: CGSize(width: 390, height: 160)
        )
        presenter.present(demo)
        demoID = demo.id
    }
    #endif
}
