import Foundation
import Observation
import os

@MainActor
@Observable
public final class IslandPresenter: IslandPresenting {
    public static let hoverEnterDelay: Duration = .milliseconds(120)
    public static let hoverExitDelay: Duration = .milliseconds(350)

    /// Insertion-ordered queue. Winner = highest priority, then latest inserted.
    public private(set) var queue: [Presentation] = []
    public private(set) var isHoverPromoted = false
    /// The card the user picked, by swiping or from the Cards menu. Cleared as soon as it
    /// leaves `stack`.
    public private(set) var pinnedID: PresentationID?

    public enum CycleDirection: Sendable { case next, previous }

    /// Carries the whole card-selection trail — swipe, cycle, pin — under one category, so
    /// `log stream --predicate 'category == "surface.swipe"'` shows a gesture end to end.
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "surface.swipe")
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private var ttlTokens: [PresentationID: ScheduledToken] = [:]
    @ObservationIgnored private var hoverToken: ScheduledToken?
    /// Whether the pointer is inside the island. Tracked separately from `isHoverPromoted`
    /// so queue changes can re-evaluate promotion without a fresh hover transition.
    @ObservationIgnored private var isHovering = false
    @ObservationIgnored private var isHoverEnterPending = false
    /// Set when the user clicks to collapse while still hovering: hover must not re-promote
    /// until the pointer leaves, otherwise the next queue change would undo the click.
    @ObservationIgnored private var hoverSuppressedUntilExit = false

    public init(clock: any IslandClock) {
        self.clock = clock
    }

    /// The cards the user can cycle between: everything queued below `.alert`, in insertion
    /// order. Alerts are interruptions, not cards — they are never part of the stack.
    public var stack: [Presentation] {
        queue.filter { $0.priority < .alert }
    }

    /// An alert always wins; otherwise the pinned card, if the user picked one and it is
    /// still queued; otherwise the plain queue winner.
    public var current: Presentation? {
        if let alert = winner(in: queue.filter { $0.priority == .alert }) { return alert }
        if let pinnedID, let pinned = stack.first(where: { $0.id == pinnedID }) { return pinned }
        return winner(in: queue)
    }

    public var state: IslandState {
        guard let current else { return .collapsed }
        if current.style == .expanded { return .expanded(current.id) }
        if isHoverPromoted, current.expanded != nil { return .expanded(current.id) }
        return .peek(current.id)
    }

    // MARK: IslandPresenting

    public func present(_ presentation: Presentation) {
        if let index = queue.firstIndex(where: { $0.id == presentation.id }) {
            queue[index] = presentation
        } else {
            queue.append(presentation)
        }
        armTTL(for: presentation)
        queueDidChange()
    }

    public func update(_ presentation: Presentation) {
        guard let index = queue.firstIndex(where: { $0.id == presentation.id }) else { return }
        queue[index] = presentation
        queueDidChange()
    }

    public func dismiss(_ id: PresentationID) {
        ttlTokens.removeValue(forKey: id)?.cancel()
        queue.removeAll { $0.id == id }
        queueDidChange()
    }

    // MARK: Card stack

    /// Index of the card the stack dots mark as current: the pinned one, else whichever
    /// card would win on its own. `nil` while the stack is empty.
    var stackIndex: Int? {
        let stack = stack
        if let pinnedID, let index = stack.firstIndex(where: { $0.id == pinnedID }) { return index }
        guard let winner = winner(in: stack) else { return nil }
        return stack.firstIndex { $0.id == winner.id }
    }

    /// Pins the neighbour of the currently displayed card, wrapping at both ends. A stack
    /// of fewer than two cards has no neighbour, so the call is a no-op. Pinning leaves
    /// hover promotion alone unless the new card cannot be expanded at all.
    public func cycle(_ direction: CycleDirection) {
        let stack = stack
        guard stack.count > 1, let index = stackIndex else { return }
        let offset = direction == .next ? 1 : stack.count - 1
        let id = stack[(index + offset) % stack.count].id
        pinnedID = id
        logger.info("cycle \(direction == .next ? "next" : "previous", privacy: .public) → pinned \(id.description, privacy: .public)")
        queueDidChange()
    }

    /// Pins a card the user picked by name (the Cards menu) rather than by cycling.
    ///
    /// Ignored unless the id is in ``stack``: alerts are interruptions rather than cards,
    /// and a card that has already left the queue must not be resurrected as a stale pin
    /// that ``queueDidChange()`` would drop on the next change anyway.
    public func pin(_ id: PresentationID) {
        guard pinnedID != id, stack.contains(where: { $0.id == id }) else { return }
        pinnedID = id
        logger.info("pin → pinned \(id.description, privacy: .public)")
        queueDidChange()
    }

    /// Drops the pin and hands the island back to the plain queue winner.
    public func unpin() {
        guard pinnedID != nil else { return }
        pinnedID = nil
        logger.info("unpin")
        queueDidChange()
    }

    // MARK: Hover

    public func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        cancelHoverTimer()
        if hovering {
            armHoverEnterIfNeeded()
        } else {
            hoverSuppressedUntilExit = false
            guard isHoverPromoted else { return }
            hoverToken = clock.schedule(after: Self.hoverExitDelay) { [weak self] in
                guard let self else { return }
                hoverToken = nil
                isHoverPromoted = false
            }
        }
    }

    public func toggleHoverPromotion() {
        cancelHoverTimer()
        isHoverPromoted.toggle()
        hoverSuppressedUntilExit = !isHoverPromoted && isHovering
    }

    // MARK: Private

    /// Highest priority, then latest inserted.
    private func winner(in presentations: [Presentation]) -> Presentation? {
        presentations.enumerated().max { a, b in
            if a.element.priority != b.element.priority { return a.element.priority < b.element.priority }
            return a.offset < b.offset
        }?.element
    }

    private func armTTL(for presentation: Presentation) {
        ttlTokens.removeValue(forKey: presentation.id)?.cancel()
        guard let ttl = presentation.ttl else { return }
        let id = presentation.id
        ttlTokens[id] = clock.schedule(after: ttl) { [weak self] in
            self?.dismiss(id)
        }
    }

    /// A presentation can be hover-promoted only if it exists, carries an expanded view, and
    /// is not already showing expanded by its own style.
    ///
    /// Alerts are included: an alert's priority decides *which* presentation is shown, not
    /// whether the user may open it. Excluding them made the whole class unopenable — the
    /// Code feature's waiting-for-you prompt could never show what it was waiting for.
    private var isHoverEligible: Bool {
        guard let current else { return false }
        return current.style == .peek && current.expanded != nil
    }

    /// The winner may have changed: keep the pin and the promotion in sync with what is
    /// now on screen. A pin only survives while its card is still part of the stack, so
    /// dismissal and TTL expiry both drop it here.
    private func queueDidChange() {
        if let pinnedID, !stack.contains(where: { $0.id == pinnedID }) {
            self.pinnedID = nil
        }
        if isHoverEligible {
            armHoverEnterIfNeeded()
        } else {
            cancelHoverTimer()
            if isHoverPromoted { isHoverPromoted = false }
        }
    }

    /// Starts the enter delay when the pointer is inside, the winner is eligible, and no
    /// promotion (or pending promotion) is already in flight.
    private func armHoverEnterIfNeeded() {
        guard isHovering, !hoverSuppressedUntilExit, !isHoverPromoted, !isHoverEnterPending, isHoverEligible else { return }
        isHoverEnterPending = true
        hoverToken = clock.schedule(after: Self.hoverEnterDelay) { [weak self] in
            guard let self else { return }
            hoverToken = nil
            isHoverEnterPending = false
            guard isHovering, isHoverEligible else { return }
            isHoverPromoted = true
        }
    }

    private func cancelHoverTimer() {
        hoverToken?.cancel()
        hoverToken = nil
        isHoverEnterPending = false
    }
}
