import AppKit
import DropZonesShared
import Foundation
import IslandCore
import QuickLookThumbnailing
import SwiftUI
import Testing
@testable import DropZonesFeature

// MARK: - Doubles

/// Local to this suite: the other suites in this target own doubles of their own.
@MainActor
private final class FakePresenter: IslandPresenting {
    var presented: [Presentation] = []
    var updated: [Presentation] = []
    var dismissed: [PresentationID] = []
    var live: [PresentationID: Presentation] = [:]
    /// Every `setSurfaceSuppressed` call, in order — the island collapsing out of the
    /// way and coming back is a visible thing, so the sequence matters.
    var suppressions: [Bool] = []

    func setSurfaceSuppressed(_ suppressed: Bool) {
        suppressions.append(suppressed)
    }

    func present(_ p: Presentation) {
        presented.append(p)
        live[p.id] = p
    }

    func update(_ p: Presentation) {
        updated.append(p)
        live[p.id] = p
    }

    func dismiss(_ id: PresentationID) {
        dismissed.append(id)
        live.removeValue(forKey: id)
    }

    /// The one card on screen for `priority`, or `nil` — the view model never has
    /// two of the same kind alive at once.
    func liveCard(_ priority: Priority) -> Presentation? {
        live.values.first { $0.priority == priority }
    }
}

@MainActor
private final class ManualClock: IslandClock {
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

@MainActor
private final class AirDropSpy {
    var calls: [[URL]] = []
    var result = true

    func send(_ urls: [URL]) -> Bool {
        calls.append(urls)
        return result
    }
}

// MARK: - Helpers

private let start = Date(timeIntervalSince1970: 1_757_000_000)

/// A 4×4 red bitmap; the provider only has to hand *an* image back.
private func makeImage() -> CGImage {
    let context = CGContext(
        data: nil,
        width: 4,
        height: 4,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return context.makeImage()!
}

/// Polls `condition` on the main actor until it holds or the timeout runs out.
///
/// The TTL and poof timers hand off to an actor (`StashStore`, `ThumbnailProvider`),
/// so their work finishes a few hops after the manual clock fires them; a fixed
/// number of `Task.yield()`s would be a guess about how many hops that is.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// Panel points (origin top-left) inside each card of a two-zone panel: the content
/// rect is inset 14 with an 8 pt gap, so the cards span x 14…136 and 144…266.
private let airDropPoint = CGPoint(x: 70, y: 70)
private let stashPoint = CGPoint(x: 200, y: 70)
private let gapPoint = CGPoint(x: 140, y: 70)

/// Everything one test needs: a temporary app-support directory, a temporary
/// defaults suite, the doubles and the view model wired to them.
@MainActor
private final class Harness {
    let root: URL
    let sources: URL
    let suite: String
    let presenter = FakePresenter()
    let clock = ManualClock()
    let airDrop = AirDropSpy()
    let settings: DropZonesSettings
    let store: StashStore
    let model: DropZonesViewModel
    /// Every `onCatcherFrameChange` call, in order: the catcher window is the only thing
    /// that draws the panel now, so when it goes up and comes down *is* the panel.
    var catcherFrames: [CGRect?] = []

    init(now: @escaping @Sendable () -> Date = { start }) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DropZonesViewModelTests-\(UUID().uuidString)")
        sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        suite = "app.notch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        settings = DropZonesSettings(defaults: defaults)

        store = StashStore(baseDirectory: root.appendingPathComponent("Notch", isDirectory: true), now: now)
        let spy = airDrop
        model = DropZonesViewModel(
            presenter: presenter,
            clock: clock,
            settings: settings,
            store: store,
            thumbnails: ThumbnailProvider(size: 22, scale: 2, generator: { _ in makeImage() }),
            airDrop: { spy.send($0) },
            viewFactory: .placeholder,
            now: now
        )
        model.onCatcherFrameChange = { [weak self] frame in self?.catcherFrames.append(frame) }
    }

    /// Lets the panel's collapse play out, which is what finally orders the catcher out.
    func finishDismissAnimation() {
        clock.advance(by: DropZonesViewModel.dismissAnimation)
    }

    @discardableResult
    func makeFile(_ name: String, contents: String = "hello") throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Opens the zones the way a real drag does.
    func enterHotRect() {
        model.handle(.enteredHotRect)
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Showing the zones

@Suite @MainActor struct DropZonesViewModelZonesTests {

    /// The panel is not an island card at all any more: the catcher's window draws it,
    /// and the island goes down to the bare notch underneath.
    @Test func enteringTheHotRectPutsTheZonesUp() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let frame = CGRect(x: 500, y: 600, width: 280, height: 140)
        harness.model.panelFrameProvider = { frame }

        harness.enterHotRect()

        #expect(harness.model.isZonesShown)
        #expect(harness.model.phase == .hovering)
        #expect(harness.model.zones == [.airDrop, .stash])
        #expect(harness.presenter.suppressions == [true])
        #expect(harness.catcherFrames == [frame])
        // Nothing is presented on the island: the stash peek is the only card this
        // feature ever puts there, and there is nothing in the stash.
        #expect(harness.presenter.presented.isEmpty)
    }

    @Test func enteringTwiceIsStillOneShowing() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.model.panelFrameProvider = { CGRect(x: 500, y: 600, width: 280, height: 140) }

        harness.enterHotRect()
        harness.enterHotRect()

        #expect(harness.model.isZonesShown)
        // Neither the island nor the window is touched a second time: everything inside
        // one showing reaches the panel through observation.
        #expect(harness.presenter.suppressions == [true])
        #expect(harness.catcherFrames.count == 1)
    }

    @Test func leavingDismissesAfterTheDebounceAndNotBefore() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()

        harness.model.handle(.leftHotRect)
        harness.clock.advance(by: .milliseconds(299))
        #expect(harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(1))
        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .idle)
        #expect(harness.presenter.suppressions == [true, false])
    }

    @Test func reEnteringWithinTheDebounceCancelsTheDismiss() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()

        harness.model.handle(.leftHotRect)
        harness.clock.advance(by: .milliseconds(200))
        harness.enterHotRect()
        harness.clock.advance(by: .seconds(2))

        #expect(harness.model.isZonesShown)
        #expect(harness.presenter.suppressions == [true])
    }

    @Test func aDragThatEndsWithoutADropDismissesAtOnce() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.model.panelFrameProvider = { CGRect(x: 500, y: 600, width: 280, height: 140) }
        harness.enterHotRect()

        // Nothing is targeted, so no drop can be on its way: no grace is owed.
        harness.model.handle(.ended)

        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .idle)
        #expect(harness.model.catcherFrameNeeded == nil)
        // The island is back at once; only the window that draws the shrinking panel is
        // still up, and nothing but that hold is left on the clock.
        #expect(harness.presenter.suppressions == [true, false])
        #expect(harness.catcherFrames.count == 1)
        #expect(harness.clock.pendingCount == 1)

        harness.finishDismissAnimation()
        #expect(harness.catcherFrames == [CGRect(x: 500, y: 600, width: 280, height: 140), nil])
        #expect(harness.clock.pendingCount == 0)
    }

    /// The defect this grace exists for: the global `.leftMouseUp` monitor fires `.ended`
    /// *before* AppKit delivers `performDragOperation`, so dismissing there ordered the
    /// catcher window out from under the drop and every drop was refused.
    @Test func aDragThatEndsOverACardHoldsTheZonesOpenForTheDrop() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let frame = CGRect(x: 500, y: 600, width: 280, height: 140)
        harness.model.panelFrameProvider = { frame }
        harness.enterHotRect()
        _ = harness.model.targeted(at: stashPoint)

        harness.model.handle(.ended)

        harness.clock.advance(by: .milliseconds(499))
        #expect(harness.model.isZonesShown)
        // The catcher is still over the panel — which is the whole point.
        #expect(harness.model.catcherFrameNeeded == frame)

        harness.clock.advance(by: .milliseconds(1))
        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .idle)
        #expect(harness.model.catcherFrameNeeded == nil)
        // The window itself outlives the panel's collapse by exactly one animation.
        #expect(harness.catcherFrames == [frame])
        harness.finishDismissAnimation()
        #expect(harness.catcherFrames == [frame, nil])
    }

    /// The drop AppKit was holding on to arrives inside the grace: it cancels it and the
    /// panel goes on to settle, rather than being torn down mid-copy.
    @Test func aDropWithinTheGraceCancelsItAndSettles() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        _ = harness.model.targeted(at: stashPoint)
        harness.model.handle(.ended)

        harness.clock.advance(by: .milliseconds(100))
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)

        #expect(harness.model.phase == .settling)
        #expect(harness.model.index.files.count == 1)
        // Only the settle is left pending: the grace is gone, not merely outrun.
        #expect(harness.clock.pendingCount == 1)

        harness.clock.advance(by: .milliseconds(400))
        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .stashed)
    }

    /// The grace expiring is the refusal path: no drop ever came, so nothing is stashed
    /// and nothing is left behind.
    @Test func aGraceThatExpiresLeavesTheStashUntouched() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        _ = harness.model.targeted(at: stashPoint)

        harness.model.handle(.ended)
        harness.clock.advance(by: .milliseconds(500))

        #expect(harness.model.index.files.isEmpty)
        #expect(harness.model.phase == .idle)
        #expect(harness.presenter.liveCard(.background) == nil)
        // Only the catcher's hold is left.
        #expect(harness.clock.pendingCount == 1)
        let stored = await harness.store.load()
        #expect(stored.files.isEmpty)
    }

    /// Escape cancels the drag outright: nothing will ever be delivered, so the panel
    /// goes at once even with a card targeted.
    @Test func aCancelledDragOverACardStillDismissesAtOnce() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        _ = harness.model.targeted(at: stashPoint)

        harness.model.handle(.cancelled)

        #expect(!harness.model.isZonesShown)
        #expect(harness.clock.pendingCount == 1)  // the catcher's hold, and nothing else
        harness.finishDismissAnimation()
        #expect(harness.clock.pendingCount == 0)
    }

    /// A new drag arriving during the grace takes the panel over rather than inheriting
    /// the last drag's mouse-up.
    @Test func aNewDragDuringTheGraceCancelsIt() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        _ = harness.model.targeted(at: stashPoint)
        harness.model.handle(.ended)

        harness.enterHotRect()
        harness.clock.advance(by: .seconds(2))

        #expect(harness.model.isZonesShown)
        #expect(harness.model.phase == .hovering)
    }

    /// The island's private Space composites above Finder's drag-image window, so
    /// anything it draws hides the thumbnail the user is dragging. It goes down to the
    /// bare notch for the drag and comes back after.
    @Test func theIslandIsSuppressedWhileTheZonesAreUp() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.enterHotRect()
        #expect(harness.presenter.suppressions == [true])

        // Updating the panel in place is not a second request.
        _ = harness.model.targeted(at: stashPoint)
        #expect(harness.presenter.suppressions == [true])

        harness.model.handle(.cancelled)
        #expect(harness.presenter.suppressions == [true, false])
    }

    @Test func stoppingUnsuppressesTheIsland() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()

        harness.model.stop()

        #expect(harness.presenter.suppressions.first == true)
        #expect(harness.presenter.suppressions.last == false)
    }

    @Test func aCancelledDragDismissesAtOnce() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()

        harness.model.handle(.cancelled)

        #expect(!harness.model.isZonesShown)
        #expect(harness.presenter.suppressions == [true, false])
    }

    @Test func noEnabledZoneMeansNothingIsPresented() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.settings.airdrop = false
        harness.settings.stash = false

        harness.enterHotRect()

        #expect(harness.model.zones.isEmpty)
        #expect(!harness.model.isZonesShown)
        #expect(harness.presenter.suppressions.isEmpty)
        #expect(harness.catcherFrames.isEmpty)
        #expect(harness.model.phase == .idle)
    }

    @Test func targetingAZoneUpdatesInPlaceAndReportsIt() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.model.panelFrameProvider = { CGRect(x: 500, y: 600, width: 280, height: 140) }
        harness.enterHotRect()

        let zone = harness.model.targeted(at: airDropPoint)

        #expect(zone == .airDrop)
        #expect(harness.model.targeted == .airDrop)
        #expect(harness.model.phase == .targeted(.airDrop))
        #expect(harness.model.animationState.targeted == .airDrop)
        // In place: the panel widens the card it is already drawing, so neither the
        // island nor the window hears about it.
        #expect(harness.presenter.suppressions == [true])
        #expect(harness.catcherFrames.count == 1)
        // 65/35 once a card is targeted (spec §2 "Widths").
        #expect(harness.model.layout.slots.first?.isTargeted == true)
    }

    @Test func aPointInTheGapTargetsNothing() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()

        #expect(harness.model.targeted(at: gapPoint) == nil)
        #expect(harness.model.phase == .hovering)

        // Targeting the second card widens it to 65 %, which moves the gap with it:
        // the cards now span x 14…99.4 and 107.4…266.
        #expect(harness.model.targeted(at: stashPoint) == .stash)
        #expect(harness.model.targeted(at: CGPoint(x: 103, y: 70)) == nil)
        #expect(harness.model.targeted == nil)
        #expect(harness.model.phase == .hovering)
    }

    @Test func leavingTheCatcherClearsTheTarget() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        _ = harness.model.targeted(at: stashPoint)

        harness.model.catcherExited()

        #expect(harness.model.targeted == nil)
        #expect(harness.model.phase == .hovering)
        #expect(harness.model.isZonesShown)
    }

    @Test func theCatcherFrameIsOfferedOnlyWhileTheZonesAreShown() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let frame = CGRect(x: 500, y: 600, width: 280, height: 140)

        // Nobody has said where the panel is yet, so there is no frame to offer even
        // with the zones up: the catcher must not be ordered in at a guessed rect.
        harness.enterHotRect()
        #expect(harness.model.isZonesShown)
        #expect(harness.model.catcherFrameNeeded == nil)
        harness.model.handle(.ended)

        harness.model.panelFrameProvider = { frame }
        #expect(harness.model.catcherFrameNeeded == nil)
        harness.enterHotRect()
        #expect(harness.model.catcherFrameNeeded == frame)
        harness.model.handle(.ended)
        #expect(harness.model.catcherFrameNeeded == nil)
    }

    /// The feature orders the catcher window in from this callback. It has to arrive in
    /// the same turn as the drag event — and, because the catcher's frame contains the
    /// hot rect, *before* the panel is presented: AppKit picks a drag's destination when
    /// the drag moves, so a window that appears a turn later under a cursor that has
    /// already stopped gets no `draggingEntered` and the drop falls through.
    @Test func theCatcherFrameIsHandedOverSynchronouslyAsTheZonesGoUpAndDown() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let frame = CGRect(x: 500, y: 600, width: 280, height: 140)
        harness.model.panelFrameProvider = { frame }

        var frames: [CGRect?] = []
        // The island is suppressed as the window goes up, so what it has been told at the
        // moment of the call says whether the notch was already clear.
        var suppressedWhenCalled: [[Bool]] = []
        harness.model.onCatcherFrameChange = { [presenter = harness.presenter] next in
            frames.append(next)
            suppressedWhenCalled.append(presenter.suppressions)
        }

        harness.enterHotRect()

        #expect(frames == [frame])
        #expect(suppressedWhenCalled == [[true]])

        // Targeting a card widens it inside the panel the window already draws, so
        // nothing is handed over again mid-drag.
        _ = harness.model.targeted(at: airDropPoint)
        #expect(frames == [frame])

        // The mouse comes up over the card, and the catcher stays: the drop AppKit is
        // about to deliver needs a window to land in (see `dropGrace`).
        harness.model.handle(.ended)
        #expect(frames == [frame])

        // The grace runs out, the panel starts shrinking — and the window that draws it
        // only goes when the collapse is over.
        harness.clock.advance(by: .milliseconds(500))
        #expect(frames == [frame])
        harness.finishDismissAnimation()
        #expect(frames == [frame, nil])
    }

    /// A drag arriving inside that hold re-uses the window still on screen rather than
    /// watching it vanish under the cursor.
    @Test func aDragThatArrivesDuringTheDismissHoldKeepsTheCatcherUp() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let frame = CGRect(x: 500, y: 600, width: 280, height: 140)
        harness.model.panelFrameProvider = { frame }
        harness.enterHotRect()
        harness.model.handle(.ended)

        harness.clock.advance(by: .milliseconds(200))
        harness.enterHotRect()
        harness.clock.advance(by: .seconds(2))

        #expect(harness.model.isZonesShown)
        // Up, down, up again — and never ordered out in between.
        #expect(harness.catcherFrames == [frame, frame])
        #expect(harness.presenter.suppressions == [true, false, true])
    }

    /// `stop()` takes the panel down, so the catcher has to come down with it — a window
    /// left over the notch after the feature is switched off would swallow every drop.
    @Test func stoppingHandsOverANilCatcherFrame() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.model.panelFrameProvider = { CGRect(x: 0, y: 0, width: 280, height: 140) }

        harness.enterHotRect()
        harness.model.stop()

        // Not after an animation nobody is watching: the window goes in this same turn.
        #expect(harness.catcherFrames.count == 2)
        #expect(harness.catcherFrames.last == .some(nil))
        #expect(harness.clock.pendingCount == 0)
    }

    /// The hot rect is 300×121 from the top of the screen; the panel is 140 tall. A
    /// cursor heading into the bottom of a card therefore leaves the rect *before* it
    /// drops, and the dismiss that arms there must not survive the drop.
    @Test func aDropCancelsAPendingLeaveDebounce() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()

        harness.model.handle(.leftHotRect)
        harness.clock.advance(by: .milliseconds(100))
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        #expect(harness.model.phase == .settling)

        // The leave was due 200 ms into this advance; only the settle may fire.
        harness.clock.advance(by: .milliseconds(399))
        #expect(harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(1))
        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .stashed)
    }

    /// The same crossing, seen the other way round: while a drop is in flight the leave
    /// is not even armed, so nothing is left to cancel.
    @Test func leavingTheHotRectWhileADropSettlesArmsNothing() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)

        harness.model.handle(.leftHotRect)
        #expect(harness.clock.pendingCount == 1)  // the settle, and nothing else
    }

    @Test func aNewDragEnteringWhileSettlingKeepsTheSettleCard() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)

        harness.model.handle(.enteredHotRect)

        #expect(harness.model.phase == .settling)
        #expect(harness.model.animationState.isSettling)
        #expect(harness.model.isZonesShown)
        harness.clock.advance(by: .milliseconds(400))
        #expect(!harness.model.isZonesShown)
    }
}

// MARK: - Dropping

@Suite @MainActor struct DropZonesViewModelDropTests {

    @Test func aStashDropSettlesThenHandsOverToTheStashPeek() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let files = [try harness.makeFile("a.txt"), try harness.makeFile("b.txt")]
        harness.enterHotRect()
        _ = harness.model.targeted(at: stashPoint)

        await harness.model.drop(urls: files, on: .stash)

        #expect(harness.model.index.files.count == 2)
        #expect(harness.model.phase == .settling)
        #expect(harness.model.animationState.isSettling)
        // Still on screen: the settle card is the same panel, drawn by the same window.
        #expect(harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(399))
        #expect(harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(1))
        #expect(harness.model.phase == .stashed)
        #expect(!harness.model.isZonesShown)
        // Only now does the island get its own card back — the stash peek.
        #expect(harness.presenter.suppressions == [true, false])

        let peek = try #require(harness.presenter.liveCard(.background))
        #expect(peek.featureID == DropZonesViewModel.featureID)
        #expect(peek.style == .peek)
        #expect(peek.expandedSize == CGSize(width: 0, height: 76))
        // The copies are real files under the temporary base directory.
        let stored = await harness.store.load()
        #expect(stored.files.count == 2)
        #expect(stored.files.allSatisfy { FileManager.default.fileExists(atPath: $0.storedPath) })
    }

    /// Files accumulate by default: a stash the user drops a second file into and finds
    /// emptied of the first is the one behaviour nobody expects.
    @Test func theDefaultStashDropAddsToWhatWasThere() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))

        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .stash)

        #expect(harness.model.index.files.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test func theStashDropActionSettingIsHonoured() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.settings.stashDropAction = .replace
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))

        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .stash)

        #expect(harness.model.index.files.map(\.name) == ["b.txt"])
    }

    @Test func theThirdZoneDoesTheOppositeAction() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))

        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .replaceStash)
        #expect(harness.model.index.files.map(\.name) == ["b.txt"])

        harness.clock.advance(by: .milliseconds(400))
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("c.txt")], on: .addToStash)
        #expect(harness.model.index.files.map(\.name) == ["b.txt", "c.txt"])
    }

    @Test func theStashPeekIsUpdatedInPlaceAcrossDrops() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))
        let peekID = try #require(harness.presenter.liveCard(.background)?.id)

        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))

        #expect(harness.presenter.liveCard(.background)?.id == peekID)
        #expect(!harness.presenter.dismissed.contains(peekID))
        #expect(harness.presenter.presented.filter { $0.priority == .background }.count == 1)
    }

    @Test func thumbnailsAreFetchedForEveryStashedFile() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(
            urls: [try harness.makeFile("a.txt"), try harness.makeFile("b.txt")],
            on: .stash
        )
        harness.clock.advance(by: .milliseconds(400))

        let filled = await waitUntil { harness.model.thumbnails.count == 2 }
        #expect(filled)
        let ids = Set(harness.model.index.files.map(\.id))
        #expect(Set(harness.model.thumbnails.keys) == ids)
    }

    @Test func anAirDropDismissesAtOnceAndSendsAfterTheDelay() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let files = [try harness.makeFile("a.txt")]
        harness.enterHotRect()

        await harness.model.drop(urls: files, on: .airDrop)

        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .idle)
        #expect(harness.airDrop.calls.isEmpty)

        harness.clock.advance(by: .milliseconds(299))
        #expect(harness.airDrop.calls.isEmpty)

        harness.clock.advance(by: .milliseconds(1))
        #expect(harness.airDrop.calls == [files])
        // The stash is not involved at all.
        #expect(harness.model.index.files.isEmpty)
        #expect(harness.presenter.liveCard(.background) == nil)
        let stored = await harness.store.load()
        #expect(stored.files.isEmpty)
    }

    /// The copy is a real hop onto the store's actor, and the mouse-up that delivered the
    /// drop — plus the hot-rect crossing that came with it — reach the global monitor
    /// while it is still running. `beforeStash` holds the drop open in `.dropped` so that
    /// window can be driven deterministically.
    @Test func dragEventsDuringTheCopyLeaveTheSettleCardAlone() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let file = try harness.makeFile("a.txt")
        harness.enterHotRect()

        var ranHook = false
        harness.model.beforeStash = { [model = harness.model, clock = harness.clock] in
            ranHook = true
            #expect(model.phase == .dropped(pending: [file]))
            model.handle(.leftHotRect)
            model.handle(.ended)
            // Neither armed anything, and neither tore the panel down on the spot.
            #expect(clock.pendingCount == 0)
            clock.advance(by: .seconds(1))
            #expect(model.isZonesShown)
        }

        await harness.model.drop(urls: [file], on: .stash)

        #expect(ranHook)
        #expect(harness.model.phase == .settling)
        #expect(harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(400))
        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .stashed)
        #expect(harness.presenter.liveCard(.background) != nil)
    }

    @Test func aSecondDropWhileSettlingIsAppliedAndRestartsTheSettle() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.settings.stashDropAction = .add
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)

        harness.clock.advance(by: .milliseconds(200))
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .stash)

        #expect(harness.model.index.files.map(\.name) == ["a.txt", "b.txt"])
        #expect(harness.model.phase == .settling)
        // The first drop's settle was due here and must have been replaced, not stacked.
        harness.clock.advance(by: .milliseconds(399))
        #expect(harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(1))
        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .stashed)
    }

    /// A settle belongs to the showing of the panel it was armed in. If that card has
    /// already gone — here an AirDrop drop took it — the settle must hand the files to
    /// the peek without dismissing whatever card is on screen by then.
    @Test func aStaleSettleDoesNotDismissAFreshPanel() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        #expect(harness.model.phase == .settling)

        harness.clock.advance(by: .milliseconds(100))
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .airDrop)
        #expect(!harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(250))
        harness.enterHotRect()
        #expect(harness.model.isZonesShown)

        harness.clock.advance(by: .milliseconds(50))  // the first drop's 400 ms is up

        // The second showing survives the first one's settle firing over it.
        #expect(harness.model.isZonesShown)
        #expect(harness.presenter.suppressions == [true, false, true])
        #expect(harness.model.phase == .hovering)
        // The files still reached the peek: only the teardown was skipped.
        #expect(harness.presenter.liveCard(.background) != nil)
        #expect(harness.model.index.files.map(\.name) == ["a.txt"])
    }

    @Test func aDropWithNoFilesIsTreatedAsADragThatJustEnded() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()

        await harness.model.drop(urls: [], on: .stash)

        #expect(!harness.model.isZonesShown)
        #expect(harness.model.index.files.isEmpty)
        #expect(harness.model.phase == .idle)
    }
}

// MARK: - Drag out

@Suite @MainActor struct DropZonesViewModelDragOutTests {

    /// Fills the stash and lands on the peek, the way every drag-out test starts.
    private func stashOneFile(_ harness: Harness) async throws {
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))
    }

    @Test func aDragOutShowsOnlyTheStashZoneAndIgnoresDropsOnIt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try await stashOneFile(harness)

        harness.model.dragOutBegan()
        #expect(harness.model.dragOutPhase == .dragging)
        #expect(harness.model.zones == [.stash])
        #expect(harness.model.animationState.isDragOut)

        harness.enterHotRect()
        let before = harness.model.index
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .stash)

        #expect(harness.model.index == before)
        #expect(harness.model.phase == .hovering)
    }

    @Test func aCompletedDragOutClearsTheStashAfterThePoof() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try await stashOneFile(harness)
        let peekID = try #require(harness.presenter.liveCard(.background)?.id)
        harness.model.dragOutBegan()
        // The drag-out passes back over the notch, so the panel opens on the stash card
        // alone; the mouse-up that ends the drag closes it again.
        harness.enterHotRect()
        #expect(harness.model.zones == [.stash])
        harness.model.handle(.ended)
        #expect(!harness.model.isZonesShown)

        harness.model.dragOutEnded(completed: true)
        #expect(harness.model.dragOutPhase == .completed)
        #expect(harness.presenter.live[peekID] != nil)

        harness.clock.advance(by: .milliseconds(249))
        #expect(harness.presenter.live[peekID] != nil)

        harness.clock.advance(by: .milliseconds(1))
        let cleared = await waitUntil { harness.presenter.live[peekID] == nil }
        #expect(cleared)
        #expect(harness.model.index.files.isEmpty)
        #expect(harness.model.dragOutPhase == .idle)
        #expect(harness.model.thumbnails.isEmpty)
        let stored = await harness.store.load()
        #expect(stored.files.isEmpty)
    }

    @Test func aCancelledDragOutLeavesTheStashAlone() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try await stashOneFile(harness)
        let peekID = try #require(harness.presenter.liveCard(.background)?.id)

        harness.model.dragOutBegan()
        harness.model.dragOutEnded(completed: false)
        harness.clock.advance(by: .seconds(1))

        // `.cancelled` stays put rather than hopping back to `.idle` where nothing could
        // ever observe it; the panel does not read it, so the zones are whole again.
        #expect(harness.model.dragOutPhase == .cancelled)
        #expect(harness.model.zones == [.airDrop, .stash])
        #expect(harness.model.index.files.count == 1)
        #expect(harness.presenter.live[peekID] != nil)
        let stored = await harness.store.load()
        #expect(stored.files.count == 1)

        // The next drag-out takes it over.
        harness.model.dragOutBegan()
        #expect(harness.model.dragOutPhase == .dragging)
    }

    @Test func aDropClearsACancelledDragOut() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try await stashOneFile(harness)
        harness.model.dragOutBegan()
        harness.model.dragOutEnded(completed: false)

        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("b.txt")], on: .stash)

        #expect(harness.model.dragOutPhase == .idle)
        // The default action adds, so the file the drag-out did not take is still there.
        #expect(harness.model.index.files.map(\.name) == ["a.txt", "b.txt"])
    }

    /// A drag-out can start out of the peek while the previous drop is still settling.
    /// The panel narrows to the stash card, and the settle still runs to its end.
    @Test func aDragOutBeginningWhileSettlingKeepsTheSettleGoing() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        #expect(harness.model.phase == .settling)

        harness.model.dragOutBegan()
        #expect(harness.model.zones == [.stash])
        #expect(harness.model.phase == .settling)

        harness.clock.advance(by: .milliseconds(400))
        #expect(!harness.model.isZonesShown)
        #expect(harness.model.phase == .stashed)
        #expect(harness.presenter.liveCard(.background) != nil)
    }
}

// MARK: - The stash's own lifecycle

@Suite @MainActor struct DropZonesViewModelStashTests {

    @Test func aPrePopulatedStashIsPresentedOnLoad() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let file = try harness.makeFile("a.txt")
        _ = await harness.store.stash([file], action: .replace)

        await harness.model.loadStash()

        #expect(harness.model.index.files.map(\.name) == ["a.txt"])
        let peek = try #require(harness.presenter.liveCard(.background))
        #expect(peek.style == .peek)
        #expect(peek.expandedSize == CGSize(width: 0, height: 76))
        #expect(harness.model.phase == .stashed)
        let filled = await waitUntil { harness.model.thumbnails.count == 1 }
        #expect(filled)
    }

    @Test func anEmptyStashPresentsNothingOnLoad() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        await harness.model.loadStash()

        #expect(harness.model.index.files.isEmpty)
        #expect(harness.presenter.presented.isEmpty)
    }

    @Test func clearingTheStashDismissesThePeek() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))
        let peekID = try #require(harness.presenter.liveCard(.background)?.id)

        await harness.model.clearStash()

        #expect(harness.presenter.dismissed.contains(peekID))
        #expect(harness.model.index.files.isEmpty)
        #expect(harness.model.thumbnails.isEmpty)
        let stored = await harness.store.load()
        #expect(stored.files.isEmpty)
        // And no expiry timer is left armed for a stash with nothing in it.
        harness.clock.advance(by: .seconds(StashIndex.ttl))
        #expect(harness.clock.pendingCount == 0)
    }

    @Test func theStashExpiresWhenItsTtlElapses() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))
        let peekID = try #require(harness.presenter.liveCard(.background)?.id)

        harness.clock.advance(by: .seconds(StashIndex.ttl))

        let expired = await waitUntil { harness.presenter.live[peekID] == nil }
        #expect(expired)
        #expect(harness.model.index.files.isEmpty)
        let stored = await harness.store.load()
        #expect(stored.files.isEmpty)
    }

    @Test func stoppingCancelsEveryTimerAndDropsBothCards() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))
        harness.enterHotRect()

        harness.model.stop()

        #expect(harness.clock.pendingCount == 0)
        #expect(harness.presenter.live.isEmpty)
        #expect(harness.model.phase == .idle)
        #expect(harness.model.dragOutPhase == .idle)
    }

    @Test func theSettingsTogglesWriteThroughAndChangeTheZoneList() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        harness.model.toggleAirDrop()
        #expect(!harness.settings.airdrop)
        #expect(harness.model.zones == [.stash])

        harness.model.toggleStashZone()
        #expect(!harness.settings.stash)
        #expect(harness.model.zones.isEmpty)

        harness.model.toggleSecondZone()
        #expect(harness.settings.secondZone)

        harness.model.setStashDropAction(.add)
        #expect(harness.settings.stashDropAction == .add)
    }

    @Test func theThirdZoneAppearsOnlyWithFilesAndTheSecondZoneSettingOn() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.model.toggleSecondZone()
        #expect(harness.model.zones == [.airDrop, .stash])

        harness.enterHotRect()
        await harness.model.drop(urls: [try harness.makeFile("a.txt")], on: .stash)
        harness.clock.advance(by: .milliseconds(400))

        #expect(harness.model.zones == [.airDrop, .stash, .replaceStash])
    }
}
