import SwiftUI
import AppKit
import IslandCore

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
    /// The row is pinned ``MusicPeekBanner/edgeInset`` from the island's edge in *both* states,
    /// and that inset is exactly where centring already put the thumbnail in the plain 56 pt
    /// slot. So the thumbnail's position inside its slot never changes: when the banner opens
    /// it travels outward with the island's own left edge and nothing else, instead of lurching
    /// to sit flush in the bottom corner's curve. The label unfolds into the new room beside it.
    var body: some View {
        HStack(spacing: MusicPeekBanner.spacing) {
            artwork
            if model.isShowingTrackChange {
                MusicPeekBanner(title: model.snapshot?.title ?? "", artist: model.snapshot?.artist)
                    .transition(.musicPeekBanner(rise: MusicMotion.trackChangeRise))
            }
        }
        .padding(.leading, MusicPeekBanner.edgeInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
            ArtworkView(data: model.artwork, size: MusicPeekBanner.artworkSize, radius: 4)
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

    static let artworkSize: CGFloat = 18
    static let spacing: CGFloat = 6

    /// How far the row stays from the island's own edge. This is exactly where centring puts
    /// the thumbnail in the plain 56 pt slot, so pinning to it moves nothing when the banner
    /// opens — and it comfortably clears the peek's 14 pt bottom-corner curve, which is what
    /// the HUD's flat 12 pt inset (`HUDBarLayout.inset`) is for. The two features cannot
    /// share the constant: features never import each other.
    static let edgeInset: CGFloat = (IslandLayout.peekSlotWidth - artworkSize) / 2

    /// A slot's inner edge *is* the notch's edge — `PeekRow` puts the notch straight after it
    /// — and the notch is a hole in the display, so a glyph that reaches the boundary is a
    /// glyph sliced in half. Text stops short of it.
    static let notchGap: CGFloat = 4

    /// Whatever the widened slot has left once the inset, the thumbnail and the two gaps are
    /// paid for. Narrow on purpose: 90 pt is the widest slot that leaves the expanded card
    /// alone, and a title too long for it scrolls.
    static let labelWidth: CGFloat =
        MusicViewModel.trackChangePeekSlotWidth - edgeInset - artworkSize - spacing - notchGap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 14, not 13: an 11 pt semibold "g" or "y" loses its descender in a 13 pt line box.
            MarqueeText(text: title, font: .system(size: 11, weight: .semibold), height: 14)
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
