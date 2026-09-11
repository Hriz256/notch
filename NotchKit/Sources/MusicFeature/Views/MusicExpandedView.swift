import SwiftUI
import AppKit

struct MusicExpandedView: View {
    @Bindable var model: MusicViewModel
    @State private var tint: Color = .clear

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(data: model.artwork, size: 64, radius: 12)
                    .onTapGesture { openSourceApp() }
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: model.snapshot?.title ?? "")
                    Text(model.snapshot?.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    AudioOutputMenu()
                    VisualizerBars(isPlaying: model.isPlaying, color: .white.opacity(0.8))
                }
            }
            TimeProgressBar(elapsed: model.displayedElapsed, duration: model.duration) { model.perform(.seek($0)) }
            TransportControls(isPlaying: model.isPlaying) { model.perform($0) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(
            RadialGradient(colors: [tint.opacity(0.12), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
        )
        .onAppear { model.startTicking(); refreshTint() }
        .onDisappear { model.stopTicking() }
        .onChange(of: model.artwork) { _, _ in refreshTint() }
    }

    @MainActor
    private func refreshTint() {
        guard let data = model.artwork else { tint = .clear; return }
        Task {
            let color = await Task.detached(priority: .utility) {
                DominantColorExtractor.averageColor(of: data) ?? .clear
            }.value
            tint = color
        }
    }

    @MainActor
    private func openSourceApp() {
        guard let bundleID = model.snapshot?.sourceBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
