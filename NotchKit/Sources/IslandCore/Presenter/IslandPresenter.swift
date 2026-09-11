import Foundation
import Observation

@MainActor
@Observable
public final class IslandPresenter: IslandPresenting {
    public static let hoverEnterDelay: Duration = .milliseconds(120)
    public static let hoverExitDelay: Duration = .milliseconds(350)

    /// Insertion-ordered queue. Winner = highest priority, then latest inserted.
    public private(set) var queue: [Presentation] = []
    public private(set) var isHoverPromoted = false

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

    public var current: Presentation? {
        queue.enumerated().max { a, b in
            if a.element.priority != b.element.priority { return a.element.priority < b.element.priority }
            return a.offset < b.offset
        }?.element
    }

    public var state: IslandState {
        guard let current else { return .collapsed }
        if current.style == .expanded { return .expanded(current.id) }
        if isHoverPromoted, current.priority < .alert, current.expanded != nil {
            return .expanded(current.id)
        }
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

    private func armTTL(for presentation: Presentation) {
        ttlTokens.removeValue(forKey: presentation.id)?.cancel()
        guard let ttl = presentation.ttl else { return }
        let id = presentation.id
        ttlTokens[id] = clock.schedule(after: ttl) { [weak self] in
            self?.dismiss(id)
        }
    }

    /// A presentation can be hover-promoted only if it exists, is not an alert, has an
    /// expanded view, and is not already showing expanded by its own style.
    private var isHoverEligible: Bool {
        guard let current else { return false }
        return current.style == .peek && current.priority < .alert && current.expanded != nil
    }

    /// The winner may have changed: keep the promotion in sync with what is now on screen.
    private func queueDidChange() {
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
