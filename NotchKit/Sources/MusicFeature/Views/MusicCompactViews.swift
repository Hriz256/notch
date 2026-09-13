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

    /// Artwork, then — for ``MusicViewModel/trackChangePeekDuration`` after a skip — the new
    /// track's title and artist beside it, in the room the widened peek slot has just made.
    ///
    /// The row is centred in the slot, so as the island grows the artwork slides left by
    /// roughly half the label's width while the island's own left edge moves left by the same
    /// amount: the thumbnail stays put on screen and the text unfolds out of the notch.
    var body: some View {
        HStack(spacing: MusicPeekBanner.spacing) {
            artwork
            if model.isShowingTrackChange {
                MusicPeekBanner(title: model.snapshot?.title ?? "", artist: model.snapshot?.artist)
                    .transition(.musicPeekBanner(rise: MusicMotion.trackChangeRise))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The island's width and this row animate on different curves, so for a few frames the
        // label is wider than the slot it lives in. Clipping to the slot turns that into the
        // shape *revealing* the text as it grows, instead of text spilling over the notch.
        .clipped()
        .animation(MusicMotion.trackChange, value: model.isShowingTrackChange)
        .musicContextMenu(model)
    }

    /// The thumbnail cross-dissolves when the track changes rather than cutting: two 18 pt
    /// images share the same frame for a quarter of a second. Keyed on the artwork's identity,
    /// so a snapshot that merely refreshes progress does not re-run it.
    private var artwork: some View {
        ZStack {
            ArtworkView(data: model.artwork, size: 18, radius: 4)
                .id(artworkIdentity)
                .transition(.opacity)
        }
        .animation(MusicMotion.artworkDissolve, value: artworkIdentity)
    }

    private var artworkIdentity: String? {
        model.snapshot?.artworkID ?? model.snapshot?.title
    }
}

/// The track-change peek's text: the new title over its artist, sized for the extra room
/// ``MusicViewModel/trackChangePeekSlotWidth`` gives the leading slot.
struct MusicPeekBanner: View {
    let title: String
    let artist: String?

    static let spacing: CGFloat = 6
    /// Whatever the widened slot has left once the 18 pt thumbnail and its gap are paid for.
    static let labelWidth: CGFloat = MusicViewModel.trackChangePeekSlotWidth - 18 - spacing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(text: title, font: .system(size: 11, weight: .semibold), height: 13)
            if let artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
    }
}

/// Fade plus a short rise: the label comes up from under the notch rather than appearing in
/// place, and goes back the way it came. `rise` is 0 under Reduce Motion, which leaves a
/// plain cross-fade.
private struct MusicPeekBannerPhase: ViewModifier {
    let active: Bool
    let rise: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .offset(y: active ? rise : 0)
    }
}

extension AnyTransition {
    static func musicPeekBanner(rise: CGFloat) -> AnyTransition {
        .modifier(
            active: MusicPeekBannerPhase(active: true, rise: rise),
            identity: MusicPeekBannerPhase(active: false, rise: rise)
        )
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
