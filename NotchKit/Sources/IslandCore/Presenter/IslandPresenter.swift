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
    /// Whether a feature has asked for the window to sit in the user's active Space (see
    /// ``IslandPresenting/setSurfaceInUserSpace(_:)``). The presenter owns no window, so
    /// it only records the request; `SurfaceController` is what acts on it.
    public private(set) var surfaceInUserSpace = false

    /// Called whenever ``surfaceInUserSpace`` changes. A direct callback rather than
    /// observation: the move has to happen in the same main-actor turn as the request —
    /// `withObservationTracking` fires its `onChange` *before* the new value is even
    /// stored, so acting on it costs a turn, and a turn here is a visible frame of the
    /// island drawn over the drag image the move exists to uncover.
    @ObservationIgnored public var onSurfaceSpaceChange: (@MainActor (Bool) -> Void)?

    public enum CycleDirection: Sendable { case next, previous }

    /// Carries the whole card-selection trail — cycle, pin, unpin — under one category, so
    /// `log stream --predicate 'category == "surface.cards"'` shows what the island is
    /// showing and why. The gesture that *asked* for a cycle is logged by
    /// ``ScrollSwipeMonitor`` under `surface.cards`' sibling, `surface.swipe`: detection and
    /// outcome are separate questions, and reading the two together tells "the gesture never
    /// fired" apart from "it fired and the stack had nowhere to go".
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "surface.cards")
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

    /// The cards the user can cycle between: every *sticky* presentation — one with no
    /// `ttl` — in insertion order, whatever its priority.
    ///
    /// Lifetime, not priority, is what separates a card from an interruption. A feature
    /// raises its own long-lived card to `.alert` to ask for attention (the Code feature
    /// does exactly that while an agent waits for the user), and that card is still a card:
    /// dropping it out of the stack made the dots flicker on every hook event and shrank
    /// the stack below two, which silently turned ``cycle(_:)`` into a no-op — the user
    /// could no longer swipe back to Music. Only a presentation that expires on its own
    /// (the 4 s completion alert) is a true interruption.
    public var stack: [Presentation] {
        queue.filter { $0.ttl == nil }
    }

    /// The interruption on screen right now, if any: a presentation that expires on its own.
    ///
    /// Lifetime is what makes it an interruption — the same rule ``stack`` is built on, read
    /// the other way round. Every transient Notch presents today is an alert (the 4 s
    /// completion card), which is why the property the views read is named for one; the
    /// filter is on `ttl` so the two halves can never disagree and leave a presentation that
    /// is neither a card nor an interruption.
    private var transientAlert: Presentation? {
        winner(in: queue.filter { $0.ttl != nil })
    }

    /// Whether ``current`` is a transient alert rather than one of the cards.
    ///
    /// The view reads this to dim every stack dot: a 4 s completion alert borrows the
    /// island from whichever card is pinned, and lighting that card's dot while the alert's
    /// own content is on screen told the user the island was on a page it was not.
    public var isShowingTransientAlert: Bool { transientAlert != nil }

    /// A transient alert always wins for as long as it lives; otherwise the pinned card, if
    /// the user picked one and it is still queued; otherwise the winning *card*.
    ///
    /// The pin outranks a *sticky* alert on purpose: the user pointing at a card is a more
    /// recent and more deliberate signal than a feature's standing request for attention.
    ///
    /// The final fallback is the winner of ``stack``, not of the whole queue, so `current`
    /// is always either the transient alert above or a member of the stack — nothing else
    /// can be on screen, and every consumer (the dots, the cards menu, cycling) can rely on
    /// that.
    public var current: Presentation? {
        if let alert = transientAlert { return alert }
        if let pinnedID, let pinned = stack.first(where: { $0.id == pinnedID }) { return pinned }
        return winner(in: stack)
    }

    public var state: IslandState {
        guard let current else { return .collapsed }
        if current.style == .expanded { return .expanded(current.id) }
        if isHoverPromoted, current.expanded != nil { return .expanded(current.id) }
        return .peek(current.id)
    }

    // MARK: IslandPresenting

    public func present(_ presentation: Presentation) {
        let previous = queue.first { $0.id == presentation.id }
        if let index = queue.firstIndex(where: { $0.id == presentation.id }) {
            queue[index] = presentation
        } else {
            queue.append(presentation)
        }
        unpinForNewStickyAlert(presentation, previous: previous)
        armTTL(for: presentation)
        queueDidChange()
    }

    public func update(_ presentation: Presentation) {
        guard let index = queue.firstIndex(where: { $0.id == presentation.id }) else { return }
        let previous = queue[index]
        let hadTTL = previous.ttl
        queue[index] = presentation
        unpinForNewStickyAlert(presentation, previous: previous)
        // An update must not restart a running countdown — a feature that refreshes its
        // alert every second would otherwise keep it alive forever. It must still arm (or
        // cancel) one when the lifetime itself changed, or a card could leave ``stack``
        // with no timer to ever take it off screen.
        if hadTTL != presentation.ttl { armTTL(for: presentation) }
        queueDidChange()
    }

    public func dismiss(_ id: PresentationID) {
        ttlTokens.removeValue(forKey: id)?.cancel()
        queue.removeAll { $0.id == id }
        queueDidChange()
    }

    public func setSurfaceInUserSpace(_ inUserSpace: Bool) {
        guard surfaceInUserSpace != inUserSpace else { return }
        surfaceInUserSpace = inUserSpace
        logger.info("surface requested in \(inUserSpace ? "user" : "private", privacy: .public) space")
        onSurfaceSpaceChange?(inUserSpace)
    }

    // MARK: Card stack

    /// Index of the card the stack dots mark as current: the pinned one, else whichever
    /// card would win on its own. `nil` while the stack is empty — and `nil` while a
    /// transient alert owns the island, because then the island is not on a card at all and
    /// a lit dot would point at a page the user is not looking at.
    var stackIndex: Int? {
        isShowingTransientAlert ? nil : selectedIndex
    }

    /// Which card is *selected*: the pinned one, else whichever card would win on its own.
    ///
    /// Unlike ``stackIndex`` this ignores a transient alert, because the selection outlives
    /// it — a swipe during the four seconds a completion alert is up still has to move the
    /// card underneath it, and the Cards menu still has a row to check.
    var selectedIndex: Int? {
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
        guard stack.count > 1, let index = selectedIndex else {
            // The no-op is logged too: without it a swipe that arrives and finds a
            // one-card stack is indistinguishable in the log from one that never arrived.
            logger.info("cycle ignored — stack of \(stack.count, privacy: .public)")
            return
        }
        let offset = direction == .next ? 1 : stack.count - 1
        let id = stack[(index + offset) % stack.count].id
        pinnedID = id
        logger.info("cycle \(direction == .next ? "next" : "previous", privacy: .public) → pinned \(id.description, privacy: .public)")
        queueDidChange()
    }

    /// Pins a card the user picked by name (the Cards menu) rather than by cycling.
    ///
    /// Ignored unless the id is in ``stack``: a transient alert is an interruption rather
    /// than a card, and a card that has already left the queue must not be resurrected as a
    /// stale pin that ``queueDidChange()`` would drop on the next change anyway.
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

    /// Drops the pin when another card starts *asking* for the user.
    ///
    /// A pin outranks a sticky alert — that is what lets the user keep watching Music while
    /// the Code card waits — but only for the alert the pin was made against. Without this,
    /// a card pinned once hid every later "waiting for you" prompt for the rest of the
    /// session: the alert arrived, lost to the pin, and nothing ever cleared the pin, so the
    /// island never said the agent was blocked.
    ///
    /// Only the *transition* into a sticky alert unpins. A feature that re-renders its
    /// waiting card every second is still asking the same question, and re-clearing the pin
    /// on every one of those updates would make the pin unusable while an agent waits.
    private func unpinForNewStickyAlert(_ presentation: Presentation, previous: Presentation?) {
        guard presentation.priority == .alert, presentation.ttl == nil else { return }
        // Already alerting: this is a refresh of the same request, not a new one.
        guard previous?.priority != .alert else { return }
        guard let pinnedID, pinnedID != presentation.id else { return }
        self.pinnedID = nil
        logger.info("unpin \(pinnedID.description, privacy: .public) — new alert \(presentation.id.description, privacy: .public)")
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
