import Foundation

/// One card in the drop-zones panel.
///
/// The raw values are persisted (a targeted zone survives in logs and in the
/// view model's `Codable` state), so they are part of the module's contract and
/// must not be renamed with the cases.
public enum Zone: String, CaseIterable, Sendable, Codable {
    case airDrop
    case stash
    case addToStash
    case replaceStash
}

/// What a drop on the stash card does to the files already there.
///
/// The raw values are exactly what `dropzones.stashDropAction` stores in
/// `UserDefaults`, so reading the setting is a plain `init(rawValue:)`.
public enum StashDropAction: String, Sendable, Codable {
    case replace
    case add
}

/// The inputs that decide which cards the panel shows, and the rule that turns
/// them into cards.
///
/// This is a value rather than a method on the view model so the whole zone
/// policy is testable without AppKit, a screen or a running drag: the view model
/// only has to keep the six flags current.
public struct ZoneState: Equatable, Sendable {
    /// `dropzones.airdrop` — whether the AirDrop card is offered at all.
    public var airdrop: Bool
    /// `dropzones.stash` — whether the File Stash card is offered at all.
    public var stash: Bool
    /// `dropzones.secondZone` — whether the *other* stash action gets its own card.
    public var secondZone: Bool
    /// `dropzones.stashDropAction` — what the main stash card does; the third card does the other one.
    public var stashDropAction: StashDropAction
    /// Whether anything is currently stashed.
    public var stashHasFiles: Bool
    /// Whether the drag in flight started from our own stash.
    public var isDragOut: Bool

    public init(
        airdrop: Bool = true,
        stash: Bool = true,
        secondZone: Bool = false,
        stashDropAction: StashDropAction = .add,
        stashHasFiles: Bool = false,
        isDragOut: Bool = false
    ) {
        self.airdrop = airdrop
        self.stash = stash
        self.secondZone = secondZone
        self.stashDropAction = stashDropAction
        self.stashHasFiles = stashHasFiles
        self.isDragOut = isDragOut
    }

    /// The cards to draw, in panel order; empty when the panel should not open.
    ///
    /// Two rules shape the result beyond the plain on/off switches:
    ///
    /// - A drag that came *out* of our stash shows only the stash card. Sending
    ///   stashed files back to the stash they came from is a no-op, and offering
    ///   AirDrop mid-drag-out would hijack a drag the user aimed somewhere else.
    ///   Everything hangs off the stash card, so with the stash zone disabled
    ///   there is no such drag to draw for and the panel stays shut.
    /// - The third card is the action the main stash card does *not* do, and it
    ///   only appears once something is stashed: with an empty stash "Add" and
    ///   "Replace" are the same drop, so a second card would just be a duplicate.
    public func zones() -> [Zone] {
        if isDragOut {
            return stash ? [.stash] : []
        }

        var result: [Zone] = []
        if airdrop { result.append(.airDrop) }
        if stash { result.append(.stash) }
        if stash, secondZone, stashHasFiles {
            result.append(stashDropAction == .replace ? .addToStash : .replaceStash)
        }
        return result
    }
}
