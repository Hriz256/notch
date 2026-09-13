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
            .animation(isReduced ? MusicMotion.pressReduced : MusicMotion.press, value: pressed)
    }
}

struct TransportControls: View {
    let isPlaying: Bool
    let perform: (PlaybackCommand) -> Void

    var body: some View {
        HStack(spacing: 24) {
            button { symbol("backward.fill", size: 16) } action: { perform(.previous) }
            button { playPauseSymbol } action: { perform(.togglePlayPause) }
            button { symbol("forward.fill", size: 16) } action: { perform(.next) }
        }
    }

    /// Play and pause are one glyph morphing, not two glyphs swapping (audit B3): the symbol
    /// renderer draws the bars sliding into the triangle. The state is applied optimistically,
    /// so this plays the instant the user clicks rather than when MediaRemote echoes back.
    ///
    /// Reduce Motion takes the plain cross-fade instead of the directional replace.
    private var playPauseSymbol: some View {
        let reduced = MusicMotion.isReduced
        return symbol(isPlaying ? "pause.fill" : "play.fill", size: 20)
            .contentTransition(reduced ? .opacity : .symbolEffect(.replace.downUp))
            .animation(reduced ? MusicMotion.symbolReplaceReduced : MusicMotion.symbolReplace,
                       value: isPlaying)
    }

    private func symbol(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
    }

    private func button<Label: View>(@ViewBuilder label: () -> Label,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle(isReduced: MusicMotion.isReduced))
    }
}
