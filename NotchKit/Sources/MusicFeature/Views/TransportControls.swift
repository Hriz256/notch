import SwiftUI
import NowPlayingClient

/// The acknowledgement every Apple control gives at mouse-down, which these three had none of
/// (audit B4): the glyph dips to 0.88 and dims, and springs back on release. It is a spring,
/// so a click that arrives while the previous release is still settling retargets from where
/// the glyph actually is instead of restarting.
///
/// Reduce Motion keeps the dimming and drops the scale — the feedback survives, the travel
/// does not.
struct TransportButtonStyle: ButtonStyle {
    /// Resolved by the caller: `ButtonStyle.makeBody` is not main-actor isolated and the
    /// Reduce Motion flag lives on `NSWorkspace`.
    let isReduced: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(pressed && !isReduced ? MusicMotion.pressedScale : 1)
            .opacity(pressed ? MusicMotion.pressedOpacity : 1)
            .animation(MusicMotion.press, value: pressed)
    }
}

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
        .buttonStyle(TransportButtonStyle(isReduced: MusicMotion.isReduced))
    }
}
