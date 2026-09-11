import SwiftUI
import NowPlayingClient

struct TransportControls: View {
    let isPlaying: Bool
    let perform: (PlaybackCommand) -> Void

    var body: some View {
        HStack(spacing: 24) {
            button("backward.fill", size: 16) { perform(.previous) }
            button(isPlaying ? "pause.fill" : "play.fill", size: 20) { perform(.togglePlayPause) }
            button("forward.fill", size: 16) { perform(.next) }
        }
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
