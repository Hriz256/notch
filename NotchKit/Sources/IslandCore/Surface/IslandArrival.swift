import CoreGraphics

/// One draw of the island, in the terms later draws are compared against: the shape, the
/// card in it, and the feature that card belongs to.
///
/// The surface keeps the previous one in `@State`, written after `body`, and every
/// question about *what kind of change this is* — which curve the shape takes, whether
/// content slides or unfolds, whether the island beats — is answered by comparing two of
/// these rather than by three separately-tracked values that could disagree.
struct IslandDraw: Equatable {
    var layout: IslandLayout
    var presentationID: PresentationID?
    var featureID: FeatureID?
}

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
    /// What the frame aims at on the beat, in points. It does not arrive: the beat is
    /// reversed after ``hold``, long before a 0.32 s spring has settled, so the island
    /// swells roughly half this far and comes back. A pulse, not a step — which is the
    /// intent, and why these numbers look larger than the movement they produce.
    static let widthBeat: CGFloat = 8
    /// The vertical half of the aim. Smaller than the width: the island is a pill, and a
    /// vertical twitch reads much louder than a horizontal one.
    static let heightBeat: CGFloat = 3
    /// How long the island pushes outward before reversing.
    static let hold: Duration = .milliseconds(90)

    /// The size the beat aims at.
    static func beat(_ size: CGSize) -> CGSize {
        CGSize(width: size.width + widthBeat, height: size.height + heightBeat)
    }

    /// What the surface should do with the beat it may already be holding.
    enum BeatChange: Equatable {
        /// Start a beat, restarting one already in flight.
        case start
        /// Drop the beat immediately and without animating: something else now owns the
        /// island's frame, and letting a 0.62-damped spring finish on top of a move the
        /// user asked for is a visible wobble on that move.
        case cancel
        case none
    }

    /// The whole policy, in one pure function.
    ///
    /// A second arrival inside the hold *restarts* the beat rather than joining it: it is
    /// a second event, and letting the first beat's timer end it would truncate it to
    /// whatever was left of the 90 ms.
    static func beatChange(arrives: Bool, layoutChanged: Bool, isHeld: Bool) -> BeatChange {
        if layoutChanged { return isHeld ? .cancel : .none }
        if arrives { return .start }
        return .none
    }

    /// Whether an arrival should be announced by a beat.
    static func shouldBeat(from previous: IslandDraw?, to next: IslandDraw, isReduced: Bool) -> Bool {
        guard !isReduced, let previous else { return false }
        // A card taking over, not the same card redrawing itself: a feature that
        // re-presents its card every second must not make the notch twitch every second.
        guard let id = next.presentationID, previous.presentationID != id else { return false }
        // Nothing to react with while the island is away, and no reaction owed while it is
        // arriving or leaving — that move is the reaction. Comparing the whole layout, not
        // just the size, keeps a radius change (which the shape animates) out of here too.
        guard next.layout.mode != .collapsed, previous.layout == next.layout else { return false }
        // One feature replacing its own card is a *change of content*, not an arrival: the
        // HUD swapping volume for brightness presents a fresh id at the same width, and a
        // notch that twitches every time the user holds a volume key is noise. A Code
        // completion alert landing over Music still beats.
        return previous.featureID != next.featureID
    }
}
