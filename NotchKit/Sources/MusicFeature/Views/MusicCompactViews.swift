import SwiftUI
import AppKit

struct ArtworkView: View {
    let data: Data?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.18)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct MusicCompactLeading: View {
    @Bindable var model: MusicViewModel
    var body: some View {
        ArtworkView(data: model.artwork, size: 18, radius: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .musicContextMenu(model)
    }
}

struct MusicCompactTrailing: View {
    @Bindable var model: MusicViewModel
    var body: some View {
        VisualizerBars(isPlaying: model.isPlaying)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .musicContextMenu(model)
    }
}
