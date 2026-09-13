import Foundation
import IslandCore

/// A clock the tests advance by hand. Same shape as the one in `DropZonesViewModelTests`.
@MainActor
final class ManualClock: IslandClock {
    private struct Entry {
        let due: Duration
        let action: @MainActor () -> Void
        let id: Int
    }

    private var entries: [Entry] = []
    private var nextID = 0
    private(set) var now: Duration = .zero

    var pendingCount: Int { entries.count }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let id = nextID
        nextID += 1
        entries.append(Entry(due: now + delay, action: action, id: id))
        return ScheduledToken { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    func advance(by delta: Duration) {
        let target = now + delta
        while let next = entries.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            entries.removeAll { $0.id == next.id }
            next.action()
        }
        now = target
    }
}

/// Records every call the view model makes on the island.
@MainActor
final class RecordingPresenter: IslandPresenting {
    private(set) var presented: [Presentation] = []
    private(set) var updated: [Presentation] = []
    private(set) var dismissed: [PresentationID] = []

    func present(_ presentation: Presentation) { presented.append(presentation) }
    func update(_ presentation: Presentation) { updated.append(presentation) }
    func dismiss(_ id: PresentationID) { dismissed.append(id) }
}
