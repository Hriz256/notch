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
    }

    public func update(_ presentation: Presentation) {
        guard let index = queue.firstIndex(where: { $0.id == presentation.id }) else { return }
        queue[index] = presentation
    }

    public func dismiss(_ id: PresentationID) {
        ttlTokens.removeValue(forKey: id)?.cancel()
        queue.removeAll { $0.id == id }
        if current == nil { clearHover() }
    }

    // MARK: Hover

    public func setHovering(_ hovering: Bool) {
        hoverToken?.cancel()
        hoverToken = nil
        if hovering {
            guard !isHoverPromoted else { return }
            hoverToken = clock.schedule(after: Self.hoverEnterDelay) { [weak self] in
                self?.isHoverPromoted = true
            }
        } else {
            guard isHoverPromoted else { return }
            hoverToken = clock.schedule(after: Self.hoverExitDelay) { [weak self] in
                self?.isHoverPromoted = false
            }
        }
    }

    public func toggleHoverPromotion() {
        hoverToken?.cancel()
        hoverToken = nil
        isHoverPromoted.toggle()
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

    private func clearHover() {
        hoverToken?.cancel()
        hoverToken = nil
        isHoverPromoted = false
    }
}
