import SwiftUI
import AppKit

struct MusicExpandedView: View {
    @Bindable var model: MusicViewModel
    @State private var tint: Color = .clear

    var body: some View {
        // Sized to fit the 128 pt of usable height left under the 32 pt notch region:
        // 56 (artwork row) + 6 + 12 (progress) + 6 + 28 (transport) + 4 + 8 padding = 120.
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                ArtworkView(data: model.artwork, size: 56, radius: 10)
                    .onTapGesture { openSourceApp() }
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: model.snapshot?.title ?? "",
                                font: .system(size: 13, weight: .semibold))
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
                .frame(height: 12)
            TransportControls(isPlaying: model.isPlaying) { model.perform($0) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
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
