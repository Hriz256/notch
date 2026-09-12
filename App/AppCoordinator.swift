import SwiftUI
import os
import CodeAgentFeature
import DropZonesFeature
import IslandCore
import MusicFeature

@MainActor
@Observable
final class AppCoordinator {
    let presenter: IslandPresenter
    let registry: FeatureRegistry
    let surface: SurfaceController
    /// Held by name as well as by the registry: the status menu talks to its settings and
    /// hook installer directly, which the type-erased `any IslandFeature` cannot offer.
    let codeFeature = CodeAgentFeature()
    /// Held by name for the same reason: the status menu reads its settings, and clears or
    /// reveals the stash through it.
    let dropZonesFeature = DropZonesFeature()
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "coordinator")
    private var demoID: PresentationID?

    init() {
        let presenter = IslandPresenter(clock: TaskClock())
        // Pages in a fixed order whatever arrives first: a stash restored at launch must
        // not push Music off the first dot.
        presenter.stackOrder = [MusicViewModel.featureID, CodeAgentViewModel.featureID, DropZonesViewModel.featureID]
        self.presenter = presenter
        self.registry = FeatureRegistry(presenter: presenter)
        self.surface = SurfaceController(presenter: presenter)
    }

    func start() {
        surface.start()
        registry.register(MusicFeature(), enabledByDefault: true)
        registry.register(codeFeature, enabledByDefault: true)
        registry.register(dropZonesFeature, enabledByDefault: true)
    }

    func stop() {
        registry.deactivateAll()
        surface.stop()
    }

    /// Tears the music feature down and brings it back: the coordinator and its XPC connection
    /// are rebuilt, which also re-requests the full now-playing state.
    ///
    /// A reload of a feature the user has switched off would silently switch it back on, so it is
    /// a no-op while the feature is disabled.
    func reloadMusic() {
        let id = MusicViewModel.featureID
        guard registry.isEnabled(id) else {
            logger.notice("Music feature is disabled: skipping helper reload")
            return
        }
        logger.info("Reloading music helper")
        registry.setEnabled(id, false)
        registry.setEnabled(id, true)
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
