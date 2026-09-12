import CoreGraphics
import Foundation

/// The pure half of `DragObserver`: global mouse events in, hot-rect crossings out.
///
/// macOS tells no application when *another* application starts a drag, so the only
/// way to notice one is to watch the global mouse and the drag pasteboard together:
/// snapshot `NSPasteboard(name: .drag).changeCount` when the button goes down, and
/// call the gesture a content drag once that count has moved *and* the pasteboard
/// carries files. Both halves matter — the count alone moves for plenty of
/// non-drag reasons, and a stale pasteboard still carries the previous drag's files.
///
/// The pasteboard is frequently filled a few events after the mouse goes down, so the
/// test repeats on every dragged event until it succeeds or the mouse goes up rather
/// than deciding once and giving up.
///
/// It holds no AppKit state and reads no clock, so the whole grammar is testable by
/// feeding it events.
public struct DragDetector: Equatable, Sendable {

    /// Where the gesture in flight stands.
    ///
    /// `dragging` carries the last known side of the hot rect, which is what makes
    /// enter and leave fire once per crossing instead of once per mouse move.
    public enum Phase: Equatable, Sendable {
        case idle
        case mouseDown
        case dragging(inHotRect: Bool)
        case cancelled
    }

    /// One global monitor callback, reduced to the `Sendable` scalars AppKit gave us.
    public enum Event: Equatable, Sendable {
        case mouseDown(changeCount: Int)
        case dragged(changeCount: Int, hasFiles: Bool, location: CGPoint)
        case flagsChanged
        case mouseUp
    }

    /// What the consumer must do about this event; `.none` for the great majority,
    /// which are mouse moves that changed nothing.
    public enum Output: Equatable, Sendable {
        case none
        case enteredHotRect
        case leftHotRect
        case ended
        case cancelled
    }

    /// The region near the notch, in screen coordinates (origin bottom-left), already
    /// clipped to the screen by the caller. Empty when there is no notch screen, and
    /// an empty rect contains nothing, so the zones simply never open.
    private let hotRect: CGRect

    /// The drag pasteboard's change count as of the last mouse-down, the baseline the
    /// content test compares against.
    private var pasteboardSnapshot = 0

    /// Only the detector may move the machine on; the consumer reads it to decide
    /// what the phases above it should show.
    public private(set) var phase: Phase = .idle

    public init(hotRect: CGRect) {
        self.hotRect = hotRect
    }

    /// Feeds one monitored event and returns what changed, if anything.
    public mutating func receive(_ event: Event) -> Output {
        switch event {
        case let .mouseDown(changeCount):
            // Always a fresh start, from any phase: a monitor can miss the mouse-up
            // that should have ended the previous gesture (another app taking the
            // event, a drag finishing in another space), and a stale snapshot would
            // then let the *next* press promote on a change count it never saw move.
            pasteboardSnapshot = changeCount
            phase = .mouseDown
            return .none

        case let .dragged(changeCount, hasFiles, location):
            switch phase {
            case .mouseDown:
                guard changeCount != pasteboardSnapshot, hasFiles else { return .none }
                // Containment is read from the very event that promoted, so a drag
                // that only becomes recognisable once it is already over the notch
                // still opens the zones instead of waiting for the next crossing.
                return enterDragging(inHotRect: hotRect.contains(location))
            case let .dragging(wasInHotRect):
                let isInHotRect = hotRect.contains(location)
                guard isInHotRect != wasInHotRect else { return .none }
                phase = .dragging(inHotRect: isInHotRect)
                return isInHotRect ? .enteredHotRect : .leftHotRect
            case .idle, .cancelled:
                // Nothing to promote, and a cancelled drag stays closed for the rest
                // of its life — the user pressed a modifier to make it go away.
                return .none
            }

        case .flagsChanged:
            // A modifier pressed mid-drag means the user is aiming at the app under
            // the cursor (copy, alias, spring-load), not at us.
            guard case .dragging = phase else { return .none }
            phase = .cancelled
            return .cancelled

        case .mouseUp:
            defer { phase = .idle }
            // `.ended` regardless of which side of the rect the drop landed on: the
            // consumer knows whether it had zones open, and a drop just outside them
            // still has to tear down the catcher window.
            guard case .dragging = phase else { return .none }
            return .ended
        }
    }

    /// Promotes to `dragging` and reports an immediate entry if the cursor is already
    /// inside the hot rect.
    private mutating func enterDragging(inHotRect: Bool) -> Output {
        phase = .dragging(inHotRect: inHotRect)
        return inHotRect ? .enteredHotRect : .none
    }
}
