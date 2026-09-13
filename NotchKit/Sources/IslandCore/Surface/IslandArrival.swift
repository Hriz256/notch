import CoreGraphics

/// The island's one-shot reaction when a new card takes it over.
///
/// The common case this exists for is the silent one: a Code completion alert arriving
/// while a 56 pt peek is already up resolves to an *identical* layout, so the shape does
/// not move at all and the event the app exists to announce is a crossfade in a box that
/// never twitches. The Dynamic Island never swaps an activity without the pill reacting.
///
/// Deliberately the conservative half of the audit's B1: the beat is played **only** when
/// the layout is otherwise unchanged. When the arrival does change the island's size, the
/// geometry spring already owns the frame and is already reacting — adding a second
/// animation to the same value there buys nothing and risks a fight between two curves.
///
/// It is the island's own frame, one value, anchored at the notch (the shape grows about
/// its centre horizontally and downward vertically), so there is no second layer and no
/// separate-shape risk by construction.
enum IslandArrival {
    /// How much wider the island goes on the beat, in points.
    static let widthBeat: CGFloat = 8
    /// How much taller. Smaller than the width: the island is a pill, and a vertical
    /// twitch reads much louder than a horizontal one.
    static let heightBeat: CGFloat = 3
    /// How long the island holds the beat before settling back.
    static let hold: Duration = .milliseconds(90)

    /// The momentarily-swollen size.
    static func beat(_ size: CGSize) -> CGSize {
        CGSize(width: size.width + widthBeat, height: size.height + heightBeat)
    }

    /// Whether an arrival should be announced by a beat.
    static func shouldBeat(
        from previous: IslandLayout?,
        to next: IslandLayout,
        presentationChanged: Bool,
        isReduced: Bool
    ) -> Bool {
        guard presentationChanged, !isReduced, let previous else { return false }
        // Nothing to react with while the island is away, and no reaction owed while it
        // is arriving or leaving — that move is the reaction.
        guard next.mode != .collapsed, previous.mode == next.mode else { return false }
        return previous.size == next.size
    }
}
