import SwiftUI
import NowPlayingClient

struct TransportControls: View {
    let isPlaying: Bool
    let perform: (PlaybackCommand) -> Void

    var body: some View {
        HStack(spacing: 28) {
            button("backward.fill", size: 18) { perform(.previous) }
            button(isPlaying ? "pause.fill" : "play.fill", size: 24) { perform(.togglePlayPause) }
            button("forward.fill", size: 18) { perform(.next) }
        }
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
