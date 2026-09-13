import Foundation
import os

/// What ``DropZonesViewModel`` asks before it deletes the files a drag-out has taken.
///
/// A seam rather than a concrete dependency so the view model's "wait for the bytes to be
/// written" rule can be tested without a real drag — the one thing the test suite cannot
/// stage.
@MainActor
public protocol DragOutPromiseTracking: AnyObject {
    /// Waits until the promises for `fileIDs` have been written — or have failed — and
    /// answers with the ids among them whose bytes were *never* asked for.
    ///
    /// Scoped to one drag-out's files on purpose: two sessions can be in flight at once,
    /// and neither one's timeout may say anything about the other's promises.
    ///
    /// Returns at once, with an empty set, when none of them is outstanding.
    func waitUntilSettled(fileIDs: Set<UUID>, timeout: Duration) async -> Set<UUID>
}

/// The promises a drag out of the stash has handed to receiving applications, and whether
/// they have been redeemed yet.
///
/// This exists because `NSDraggingSource.draggingSession(_:endedAt:operation:)` reports a
/// *non-empty operation* the moment the receiver accepts the drop, not when it asks for the
/// bytes. Finder asks straight away; Mail's compose window, Electron apps and anything that
/// copies lazily can ask seconds later. The stash used to delete its copies 250 ms after the
/// session ended, so `StashStore.write(file:to:)` then threw `fileNoSuchFile` and the file
/// the user had just dragged somewhere — quite possibly their only copy — was gone.
///
/// So every promise is registered as the session starts and settled when its write finishes,
/// success or failure, and the view model waits for a session's own promises to be in before
/// it deletes that session's bytes — the entries leave the shelf without waiting, and a file
/// whose promise never comes simply keeps its bytes until the orphan sweep.
///
/// `@MainActor` rather than an actor on purpose: registration happens on the main actor,
/// where the drag starts, so it is *synchronous* and can never be a turn late. Settling
/// hops from the promise queue, so it can only ever be late — which delays a deletion and
/// never causes an early one.
@MainActor
public final class DragOutPromiseTracker: DragOutPromiseTracking {

    /// How often ``waitUntilSettled(fileIDs:timeout:)`` looks again.
    ///
    /// Polling rather than continuations: the wait happens once per drag-out and almost
    /// always finds nothing outstanding at all (one comparison, no sleep), and a parked
    /// continuation that the timeout has to race is a leak waiting to happen — there is no
    /// way to resume one from the losing side of a task group.
    static let pollInterval: Duration = .milliseconds(50)

    /// File id → how many promises for that file are still unredeemed. A count rather
    /// than a set because the same file can be dragged out twice before the first
    /// receiver has got round to asking for it.
    private var outstanding: [UUID: Int] = [:]
    private let logger = Logger(subsystem: "app.notch", category: "dropzones.dragout")

    public init() {}

    /// The files whose bytes have been promised and not yet written.
    public var outstandingFileIDs: Set<UUID> { Set(outstanding.keys) }

    /// A promise for `fileID` is on the pasteboard. Called as the session begins, on the
    /// main actor, before any receiver can possibly have asked for it.
    public func register(fileID: UUID) {
        outstanding[fileID, default: 0] += 1
    }

    /// The receiver has been given its bytes, or the write failed and it has been told so.
    /// Either way the stash no longer owes anybody that file.
    public func settle(fileID: UUID) {
        guard let count = outstanding[fileID] else { return }
        if count <= 1 {
            outstanding.removeValue(forKey: fileID)
        } else {
            outstanding[fileID] = count - 1
        }
    }

    public func waitUntilSettled(fileIDs: Set<UUID>, timeout: Duration) async -> Set<UUID> {
        guard !outstandingFileIDs(among: fileIDs).isEmpty else { return [] }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !outstandingFileIDs(among: fileIDs).isEmpty, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                // Cancelled: the caller is being torn down. Not a timeout — nothing is
                // given up on, and nothing is logged as if a receiver had gone quiet.
                return outstandingFileIDs(among: fileIDs)
            }
        }
        let unredeemed = outstandingFileIDs(among: fileIDs)
        guard !unredeemed.isEmpty else { return [] }
        // Not waited on any longer: the receiver almost always took the file *URL* the
        // pasteboard also carries and never had a promise to redeem, and in the rare other
        // case (a receiver that crashed, a drop it abandoned) it never will. Either way a
        // registration left standing would make every later drag-out wait the full timeout
        // too. The bytes are not lost: they stay on disk until the orphan sweep.
        logger.info("""
            \(unredeemed.count, privacy: .public) file promise(s) were not redeemed within the \
            timeout; the receiver took the URL, the bytes stay until the orphan sweep
            """)
        // Only this session's: another drag-out may be in flight, and forgetting *its*
        // promises here would let its files' bytes be deleted from under a receiver that
        // has not asked for them yet.
        for id in unredeemed { outstanding.removeValue(forKey: id) }
        return unredeemed
    }

    /// The subset of `fileIDs` that is still owed to somebody.
    private func outstandingFileIDs(among fileIDs: Set<UUID>) -> Set<UUID> {
        fileIDs.filter { outstanding[$0] != nil }
    }
}
