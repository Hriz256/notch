import Foundation
import Testing
@testable import DropZonesFeature

/// The object the drag-out data-loss fix rests on: promises registered as a session begins,
/// settled as each write finishes, and a wait that only gives up after the timeout.
@MainActor
struct DragOutPromiseTrackerTests {
    @Test func nothingOutstandingReturnsAtOnce() async {
        let tracker = DragOutPromiseTracker()
        let start = ContinuousClock.now
        let left = await tracker.waitUntilSettled(timeout: .seconds(5))
        #expect(left.isEmpty)
        #expect(ContinuousClock.now - start < .milliseconds(40))
    }

    @Test func registerThenSettleLeavesNothing() async {
        let tracker = DragOutPromiseTracker()
        let id = UUID()
        tracker.register(fileID: id)
        #expect(tracker.outstandingFileIDs == [id])
        tracker.settle(fileID: id)
        #expect(tracker.outstandingFileIDs.isEmpty)
        #expect(await tracker.waitUntilSettled(timeout: .seconds(1)).isEmpty)
    }

    @Test func theSameFilePromisedTwiceNeedsTwoSettles() {
        let tracker = DragOutPromiseTracker()
        let id = UUID()
        tracker.register(fileID: id)
        tracker.register(fileID: id)
        tracker.settle(fileID: id)
        #expect(tracker.outstandingFileIDs == [id])
        tracker.settle(fileID: id)
        #expect(tracker.outstandingFileIDs.isEmpty)
    }

    @Test func settlingAnUnknownIDIsHarmless() {
        let tracker = DragOutPromiseTracker()
        tracker.settle(fileID: UUID())
        #expect(tracker.outstandingFileIDs.isEmpty)
    }

    @Test func theWaitReturnsOnceEverythingIsSettled() async {
        let tracker = DragOutPromiseTracker()
        let id = UUID()
        tracker.register(fileID: id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            tracker.settle(fileID: id)
        }
        let left = await tracker.waitUntilSettled(timeout: .seconds(5))
        #expect(left.isEmpty)
    }

    @Test func theTimeoutReturnsTheUnredeemedIDsAndForgetsThem() async {
        let tracker = DragOutPromiseTracker()
        let id = UUID()
        tracker.register(fileID: id)
        let left = await tracker.waitUntilSettled(timeout: .milliseconds(120))
        #expect(left == [id])
        // Forgotten, so the next drag-out does not pay for this one.
        #expect(tracker.outstandingFileIDs.isEmpty)
        #expect(await tracker.waitUntilSettled(timeout: .seconds(1)).isEmpty)
    }

    @Test func cancellationReturnsWithoutGivingUp() async {
        let tracker = DragOutPromiseTracker()
        let id = UUID()
        tracker.register(fileID: id)
        let waiter = Task { @MainActor in
            await tracker.waitUntilSettled(timeout: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(80))
        waiter.cancel()
        let left = await waiter.value
        #expect(left == [id])
        // Still on record: a cancelled wait is teardown, not a receiver gone quiet.
        #expect(tracker.outstandingFileIDs == [id])
    }
}
