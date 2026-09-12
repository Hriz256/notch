import AppKit
import DropZonesShared
import Foundation
import IslandCore
import Observation
import SwiftUI
import os

/// Builds the island views for the Drop Zones feature. Injected so the view model is
/// testable without SwiftUI rendering, exactly like `CodeViewFactory`.
@MainActor
public struct DropZonesViewFactory {
    /// The expanded panel while a drag is over the notch: the cards, and — once a
    /// drop has landed — the full-width settle card.
    public var zones: (DropZonesViewModel) -> AnyView
    /// Peek leading slot: the thumbnail stack.
    public var stashLeading: (DropZonesViewModel) -> AnyView
    /// Peek trailing slot: the file-count circle.
    public var stashTrailing: (DropZonesViewModel) -> AnyView
    /// Hover-expanded stash card: the peek row plus the caption.
    public var stashExpanded: (DropZonesViewModel) -> AnyView

    public init(
        zones: @escaping (DropZonesViewModel) -> AnyView,
        stashLeading: @escaping (DropZonesViewModel) -> AnyView,
        stashTrailing: @escaping (DropZonesViewModel) -> AnyView,
        stashExpanded: @escaping (DropZonesViewModel) -> AnyView
    ) {
        self.zones = zones
        self.stashLeading = stashLeading
        self.stashTrailing = stashTrailing
        self.stashExpanded = stashExpanded
    }

    /// Draws nothing. `Color.clear` rather than `EmptyView` so a placeholder card
    /// still occupies its slot in layout tests.
    public static let placeholder = DropZonesViewFactory(
        zones: { _ in AnyView(Color.clear) },
        stashLeading: { _ in AnyView(Color.clear) },
        stashTrailing: { _ in AnyView(Color.clear) },
        stashExpanded: { _ in AnyView(Color.clear) }
    )
}

/// Where a drag-and-drop over the notch stands.
///
/// `hovering` is "the zones are up with nothing targeted"; `targeted` carries the card
/// the cursor is over. `dropped` holds the files between the drop and the copy finishing,
/// so the panel can show them before the disk has caught up, and `settling` is the
/// full-width "N Files" card that plays before the island collapses.
public enum StashPhase: Equatable, Sendable {
    case idle
    case hovering
    case targeted(Zone)
    case dropped(pending: [URL])
    case settling
    case stashed
}

/// Where a drag that started *from* our stash stands. `completed` is the only one that
/// clears the stash, and only after the poof has played.
///
/// Only a whole-stash drag-out reaches ``completed``: a single file leaving is a change
/// to the pile rather than the end of it, and the card that poofs is that one tile (see
/// ``DropZonesViewModel/poofingFileIDs``).
public enum DragOutPhase: Equatable, Sendable {
    case idle
    case dragging
    case completed
    case cancelled
}

/// How much of the stash a drag-out was carrying.
///
/// The compact fan in the peek is one handle for everything in the stash; each tile in the
/// hover-expanded row is a handle for its own file. Both start the same `.dragging` phase —
/// the panel must offer the stash card alone either way — and they differ only in what a
/// completed session takes with it.
public enum DragOutScope: Equatable, Sendable {
    case all
    case single(UUID)
}

/// Everything the zones panel animates on, in one `Equatable` value.
///
/// SwiftUI re-runs an `.animation(_:value:)` whenever the value changes, so bundling the
/// five things that matter keeps one animation in charge of the whole panel instead of
/// several racing ones.
public struct AnimationState: Equatable, Sendable {
    public var zones: [Zone]
    public var targeted: Zone?
    public var hasPending: Bool
    public var isDragOut: Bool
    public var isSettling: Bool

    public init(
        zones: [Zone],
        targeted: Zone?,
        hasPending: Bool,
        isDragOut: Bool,
        isSettling: Bool
    ) {
        self.zones = zones
        self.targeted = targeted
        self.hasPending = hasPending
        self.isDragOut = isDragOut
        self.isSettling = isSettling
    }
}

/// Turns drag events, drops and the stash on disk into the two island presentations
/// (spec §3.2).
///
/// Two presentations, never more:
///
/// - **the zones** — a `.alert` `.expanded` card, 280×140, alive only while a drag is
///   over the notch. Its id is fresh per showing (each drag is its own card, and a new
///   id is what gives the panel a clean entrance), but within one showing it is updated
///   in place: targeting a card must widen it, not blink the panel away and back.
/// - **the stash** — a `.background` peek that lives as long as there are files in the
///   stash, updated in place as files and thumbnails change.
///
/// The view model owns no windows. `DragObserver` feeds it `handle(_:)`, the catcher
/// window asks it `targeted(at:)` / `drop(urls:on:)`, and it calls
/// ``onCatcherFrameChange`` — synchronously, before the panel is presented — so the
/// feature can order that window in.
@MainActor
@Observable
public final class DropZonesViewModel {

    // MARK: - Constants

    public static let featureID = FeatureID("dropzones")
    /// What this feature's cards are called in menus.
    public static let displayTitle = "Drop Zones"
    /// The zones panel (spec §2 "Widths").
    public static let zonesSize = CGSize(width: 280, height: 140)
    /// The hover-expanded stash card: 380 pt wide like the Music and Code cards — the user
    /// wants every page the same width — and 124 pt tall, the peek row (a notch tall) over
    /// the 40 pt tile row and the caption. `StashRowLayout` owns that arithmetic, including
    /// how many tiles 380 pt holds.
    ///
    /// The top row is a real `PeekRow`, whose two slots hug the island's edges at whatever
    /// width it is given: hovering widens the island, so the slots slide outward with it
    /// rather than staying where the peek had them. That is the user's ask — the card is a
    /// page like the others first, and a grown peek second.
    public static let stashExpandedSize = CGSize(width: 380, height: 124)
    /// How long the zones stay up after the cursor leaves the hot rect, so a drag that
    /// clips the corner on its way somewhere else does not flicker them.
    public static let leaveDebounce: Duration = .milliseconds(300)
    /// How long the zones stay up after the mouse comes up *over a card*, waiting for
    /// AppKit to deliver the drop.
    ///
    /// The global `.leftMouseUp` monitor fires `.ended` the instant the button is
    /// released, but AppKit only sends `prepareForDragOperation` /
    /// `performDragOperation` to the destination *after* that same mouse-up has been
    /// processed. Dismissing on `.ended` ordered the catcher window out from under the
    /// drop, and every drop was refused: the cards highlighted, Finder showed the copy
    /// badge, and nothing was ever stashed. Seam holds the panel open the same way.
    public static let dropGrace: Duration = .milliseconds(500)
    /// How long the "N Files" settle card plays before the island collapses.
    public static let settleDelay: Duration = .milliseconds(400)
    /// The pause between the zones collapsing and the AirDrop sheet appearing.
    public static let airDropDelay: Duration = .milliseconds(300)
    /// The poof after a completed drag-out, before the stash is emptied.
    public static let poofDuration: Duration = .milliseconds(250)
    /// How long the stash waits for a receiver to redeem the promises a drag-out handed it
    /// before deleting the files anyway.
    ///
    /// The poof still plays at ``poofDuration`` — the tile fades on time — but the copies
    /// on disk are the user's only ones until the receiver has actually asked for the
    /// bytes, and a lazy receiver (Mail's compose window, anything Electron) asks seconds
    /// after accepting the drop. 15 s is long enough for a big file over a slow volume and
    /// short enough that a receiver which crashed does not hold the stash for ever; when it
    /// runs out the files nobody asked for are *kept* rather than deleted.
    public static let promiseSettleTimeout: Duration = .seconds(15)
    /// How long after the panel comes down the island keeps drawing itself from the
    /// mirror window (`IslandPresenting.setSurfaceMirrored(_:)`).
    ///
    /// The swap between the two windows is only invisible while the island is *static*,
    /// and the zones' collapse is the longest animation a drag leaves behind: releasing on
    /// the mouse-up would trade the windows mid-collapse, one frame ahead of the other.
    /// 500 ms clears the spring with room to spare, and nothing about the island is
    /// different in the meantime — the mirror is a copy of the same presenter.
    public static let mirrorRelease: Duration = .milliseconds(500)

    // MARK: - Published state

    /// What is in the stash right now; the peek and the expanded card are built from it.
    public private(set) var index = StashIndex()
    public private(set) var phase: StashPhase = .idle
    public private(set) var dragOutPhase: DragOutPhase = .idle
    /// The card the cursor is over, `nil` in the gaps and margins.
    public private(set) var targeted: Zone?
    /// Thumbnails by ``StashedFile/id``, filled in the background after the index changes.
    public private(set) var thumbnails: [UUID: Thumbnail] = [:]
    /// The tiles playing their own poof: fading and shrinking on their way out of the row,
    /// a file at a time. Empty except in the ``poofDuration`` between a single file being
    /// taken and its copy on disk going.
    public private(set) var poofingFileIDs: Set<UUID> = []
    /// Whether the zones presentation is on screen. Stored rather than derived from the
    /// presentation id so views observe it.
    public private(set) var isZonesShown = false

    /// The cards to draw, derived from the settings, the stash and the drag in flight.
    public var zones: [Zone] { zoneState.zones() }

    /// Where those cards sit in the 280×140 panel, including the targeted card's extra width.
    public var layout: ZoneLayout { ZoneLayout.resolve(zones: zones, targeted: targeted) }

    public var animationState: AnimationState {
        AnimationState(
            zones: zones,
            targeted: targeted,
            hasPending: pendingURLs != nil,
            isDragOut: dragOutPhase == .dragging,
            isSettling: phase == .settling
        )
    }

    /// The files a drop handed us, while they are being copied. The settle card shows
    /// their count before the stash has one.
    public var pendingURLs: [URL]? {
        guard case let .dropped(pending) = phase else { return nil }
        return pending
    }

    /// Where the drop catcher window has to be, or `nil` when it should be ordered out.
    ///
    /// The catcher only exists to receive drops on cards that are on screen, so this is
    /// exactly "the panel's frame while the zones are shown" — and `nil` until the
    /// feature has told us where the panel is, so the catcher is never ordered in at a
    /// frame nobody has computed yet.
    ///
    /// Read-only convenience: the feature is *told* this value through
    /// ``onCatcherFrameChange`` rather than polling it, because the window has to be in
    /// place in the same turn the zones go up.
    public var catcherFrameNeeded: CGRect? {
        guard isZonesShown, let panelFrameProvider else { return nil }
        return panelFrameProvider()
    }

    // MARK: - Collaborators

    /// The island this feature presents on. Exposed read-only so the feature's context
    /// menu can embed `CardsMenuSection`, which needs the presenter to list the cards.
    @ObservationIgnored public let islandPresenter: any IslandPresenting
    /// Read by the context menu and the status-menu submenu.
    @ObservationIgnored public let settings: DropZonesSettings
    /// Where the zones panel is on screen, in screen coordinates. Set by the feature once
    /// it knows the island's geometry; `nil` until then, which makes ``catcherFrameNeeded``
    /// `nil` too, so the catcher is never ordered in at a frame nobody has computed.
    @ObservationIgnored public var panelFrameProvider: (@MainActor () -> CGRect)?
    /// Called with ``catcherFrameNeeded`` whenever the zones go up (the panel's frame)
    /// or come down (`nil`). Set by the feature, which orders the catcher window in and
    /// out inline.
    ///
    /// A direct callback rather than observation, and called *before* the panel is
    /// presented: the catcher's frame contains the whole hot rect, so by the time the
    /// window appears the cursor is usually already inside it — and AppKit only picks a
    /// drag's destination when the drag *moves*. A window ordered in one main-actor turn
    /// later (which is the best `withObservationTracking` can do, its `onChange` firing
    /// before the new value is even stored) would miss a cursor that entered the notch
    /// and stopped: no `draggingEntered`, and the drop falls through to whatever is
    /// behind the island.
    @ObservationIgnored public var onCatcherFrameChange: (@MainActor (CGRect?) -> Void)?
    /// A line describing the drop catcher's state, logged when a mouse-up over a card is
    /// never followed by a drop. Set by the feature; `nil` in tests, where there is no
    /// window to describe.
    ///
    /// The catcher is the one part of the path that can fail silently — a window AppKit
    /// never considered for the drag delivers no `draggingEntered` and no drop, and looks
    /// from here exactly like a user who let go a pixel outside the card.
    @ObservationIgnored public var catcherDiagnostics: (@MainActor () -> String)?
    /// The promises a drag out of the stash has handed to receiving applications. The
    /// drag source registers them; the model waits on them before deleting anything (see
    /// ``promiseSettleTimeout``).
    @ObservationIgnored public let promises = DragOutPromiseTracker()

    @ObservationIgnored private let clock: any IslandClock
    /// The stash on disk. Exposed because the drag-out source has to hand its promise
    /// delegate the one object allowed to touch the stash directory.
    @ObservationIgnored public let store: StashStore
    @ObservationIgnored private let thumbnailProvider: ThumbnailProvider
    @ObservationIgnored private let airDrop: @MainActor ([URL]) -> Bool
    @ObservationIgnored private let viewFactory: DropZonesViewFactory
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "dropzones.viewmodel")

    // MARK: - Private state

    @ObservationIgnored private var zonesID: PresentationID?
    @ObservationIgnored private var stashID: PresentationID?
    @ObservationIgnored private var leaveToken: ScheduledToken?
    @ObservationIgnored private var dropGraceToken: ScheduledToken?
    @ObservationIgnored private var settleToken: ScheduledToken?
    @ObservationIgnored private var airDropToken: ScheduledToken?
    @ObservationIgnored private var poofToken: ScheduledToken?
    /// One per tile currently poofing on its own, so a second file leaving does not cancel
    /// the first one's fade.
    @ObservationIgnored private var filePoofTokens: [UUID: ScheduledToken] = [:]
    @ObservationIgnored private var fileRemovalTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var mirrorToken: ScheduledToken?
    /// Whether the island is currently drawing from the mirror window *at this feature's
    /// request*. Kept here rather than read back off the presenter because the protocol
    /// only offers the setter — and because it is what makes the calls idempotent.
    @ObservationIgnored private var isMirrored = false
    /// Set when a drag ends while the panel is still on screen: the mirror is released
    /// ``mirrorRelease`` after the panel comes down rather than straight away.
    @ObservationIgnored private var isMirrorReleasePending = false
    /// Set by ``stop()`` and never cleared: the feature builds a fresh model on every
    /// activation, so a stopped one is finished for good.
    ///
    /// Checked after every `await` in this class. A drop whose copy was still in flight
    /// when the feature was switched off used to come back and present its settle card
    /// into an island that no longer had a drag observer, a catcher or a way to dismiss
    /// it — a card the user could not get rid of.
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var expiryToken: ScheduledToken?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    /// The two timers hand off to an actor, so each also owns a `Task`; held here so
    /// ``stop()`` can cancel the work the timer already started, not just the timer.
    @ObservationIgnored private var poofTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// Test seam. Awaited inside ``drop(urls:on:)`` after the drop has been recorded as
    /// ``StashPhase/dropped(pending:)`` and before the copy starts, so a test can drive
    /// events into the window where `store.stash` is in flight. Never set in shipping
    /// code; `internal` so only `@testable` code can reach it.
    @ObservationIgnored var beforeStash: (@MainActor () async -> Void)?

    /// Test seam. What the model waits on before deleting files a drag-out has taken;
    /// ``promises`` in shipping code, a double in the tests, which cannot stage a real
    /// file promise. `internal` so only `@testable` code can reach it.
    @ObservationIgnored var promiseTracker: (any DragOutPromiseTracking)?

    private var settlingPromises: any DragOutPromiseTracking { promiseTracker ?? promises }

    public init(
        presenter: any IslandPresenting,
        clock: any IslandClock,
        settings: DropZonesSettings,
        store: StashStore,
        thumbnails: ThumbnailProvider,
        airDrop: @escaping @MainActor ([URL]) -> Bool,
        viewFactory: DropZonesViewFactory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.islandPresenter = presenter
        self.clock = clock
        self.settings = settings
        self.store = store
        self.thumbnailProvider = thumbnails
        self.airDrop = airDrop
        self.viewFactory = viewFactory
        self.now = now
    }

    private var zoneState: ZoneState {
        ZoneState(
            airdrop: settings.airdrop,
            stash: settings.stash,
            secondZone: settings.secondZone,
            stashDropAction: settings.stashDropAction,
            stashHasFiles: !index.files.isEmpty,
            isDragOut: dragOutPhase == .dragging
        )
    }

    // MARK: - Drag input

    /// Folds one `DragObserver` output into the zones presentation.
    public func handle(_ output: DragDetector.Output) {
        switch output {
        case .began:
            // Mirroring is armed here — at the start of the drag, anywhere on screen —
            // rather than when the zones open, so the mirror window has already rendered
            // the island as it stands before the panel is presented into it. Swapped a
            // turn later, SwiftUI coalesces the mirror's first render with the expansion
            // and the panel appears fully grown instead of growing out of the notch.
            //
            // Nothing enabled means no panel will ever open for this drag, so there is
            // nothing for the drag image to be hidden behind.
            guard !zones.isEmpty else { return }
            mirrorSurface()

        case .enteredHotRect:
            // Nothing enabled (or a drag out of a stash whose card is switched off) means
            // there is no panel to open; the catcher stays out and the drop goes to
            // whatever is under the cursor.
            guard !zones.isEmpty else { return }
            cancelLeave()
            // A fresh drag over a panel still waiting on the last one's drop: the grace
            // belongs to a mouse-up that is now history.
            cancelDropGrace()
            // A settle card still playing owns the panel: a new drag entering must not
            // blank it back to an empty hover half way through the animation. Targeting
            // resumes the moment the cursor is actually over a card.
            if !isDropInFlight {
                targeted = nil
                phase = .hovering
            }
            showZones()

        case .leftHotRect:
            // The hot rect is shorter than the panel, so a cursor that dips into the
            // bottom of a card leaves it: arming the dismiss while a drop is being
            // copied or settling would cut the settle card short.
            guard isZonesShown, !isDropInFlight else { return }
            cancelLeave()
            leaveToken = clock.schedule(after: Self.leaveDebounce) { [weak self] in
                guard let self else { return }
                leaveToken = nil
                dismissZones()
                phase = .idle
            }

        case .ended:
            // The drag is over wherever it ended, so the mirror is owed back — before the
            // guard below, which returns for every drag that never opened a panel.
            armMirrorRelease()
            // A drop that reached us owns the teardown from here: the settle card is the
            // zones presentation, and the mouse-up that delivered the drop must not pull
            // it out from under the animation.
            guard isZonesShown, !isDropInFlight else { return }
            cancelLeave()
            // The mouse came up over a card, so a drop is almost certainly on its way —
            // AppKit just has not delivered it yet (see ``dropGrace``). Hold everything
            // in place, catcher included, until it arrives or the grace runs out.
            guard targeted == nil else {
                armDropGrace()
                return
            }
            dismissZones()
            phase = .idle

        case .cancelled:
            armMirrorRelease()
            guard isZonesShown, !isDropInFlight else { return }
            cancelLeave()
            // Escape during the drag: nothing will be delivered, so no grace is owed.
            cancelDropGrace()
            dismissZones()
            phase = .idle
        }
    }

    /// Holds the zones (and with them the catcher window) open for ``dropGrace`` after a
    /// mouse-up over a card, then closes up as `.ended` would have.
    private func armDropGrace() {
        cancelDropGrace()
        // The grace belongs to *this* showing. A panel that has since been dismissed and
        // re-presented for a new drag is somebody else's card to take down.
        let showing = zonesID
        dropGraceToken = clock.schedule(after: Self.dropGrace) { [weak self] in
            guard let self else { return }
            dropGraceToken = nil
            // The catcher's own state goes in the same line: "no drop arrived" and "the
            // catcher was never even asked" look identical from here, and only the second
            // one is a bug in our window handling.
            logger.info("""
                no drop arrived within the grace; closing the zones — \
                \(self.catcherDiagnostics?() ?? "no catcher attached", privacy: .public)
                """)
            guard zonesID == showing, !isDropInFlight else { return }
            dismissZones()
            phase = .idle
        }
    }

    private func cancelDropGrace() {
        dropGraceToken?.cancel()
        dropGraceToken = nil
    }

    // MARK: - The surface mirror

    /// Asks the island to draw itself from its mirror window — the one in the ordinary
    /// user Space, under the system's drag image — for the rest of this drag.
    ///
    /// Without it the dragged file's thumbnail disappears behind the zones panel: the
    /// island's private SkyLight Space composites above the drag image (spec, "Known gap").
    ///
    /// This is also the release safety. A mouse-up the global monitors never saw — another
    /// application taking the event, a drag finishing in another Space — leaves the mirror
    /// engaged with nothing to release it. Rather than a second mechanism to detect that,
    /// the *next* drag simply adopts the mirror that is already up (the guard below), and
    /// its own `.ended` releases it the usual way. Nothing is visibly wrong in the
    /// meantime: the mirror draws the same presenter as the primary, and the primary is
    /// still there at alpha 0 taking every click.
    private func mirrorSurface() {
        cancelMirrorRelease()
        guard !isMirrored else { return }
        isMirrored = true
        islandPresenter.setSurfaceMirrored(true)
    }

    /// The drag is over: give the pixels back to the primary window once whatever it left
    /// on screen has finished collapsing.
    private func armMirrorRelease() {
        guard isMirrored else { return }
        // A panel still up (or a drop still landing) owns the mirror until it comes down;
        // ``dismissZones()`` starts the countdown then. A drag that never opened one — it
        // passed nowhere near the notch, or the user let go outside it — has nothing to
        // wait for.
        guard isZonesShown || isDropInFlight else {
            releaseMirror()
            return
        }
        isMirrorReleasePending = true
    }

    /// Starts the post-collapse countdown. Called from ``dismissZones()`` so every way the
    /// panel can come down — the grace expiring, a settle finishing, an AirDrop hand-over —
    /// releases the mirror the same way.
    private func scheduleMirrorRelease() {
        isMirrorReleasePending = false
        mirrorToken?.cancel()
        mirrorToken = clock.schedule(after: Self.mirrorRelease) { [weak self] in
            guard let self else { return }
            mirrorToken = nil
            releaseMirror()
        }
    }

    private func releaseMirror() {
        cancelMirrorRelease()
        guard isMirrored else { return }
        isMirrored = false
        islandPresenter.setSurfaceMirrored(false)
    }

    private func cancelMirrorRelease() {
        mirrorToken?.cancel()
        mirrorToken = nil
        isMirrorReleasePending = false
    }

    /// Whether a drop is being copied or settling, which is when the zones presentation
    /// belongs to the drop rather than to the drag.
    private var isDropInFlight: Bool {
        if case .dropped = phase { return true }
        return phase == .settling
    }

    // MARK: - Catcher input

    /// The zone under `point` (panel coordinates, origin top-left), also adopting it as
    /// the targeted card. `nil` in the gaps, the margins, and while nothing is shown.
    public func targeted(at point: CGPoint) -> Zone? {
        guard isZonesShown else { return nil }
        let zone = layout.hitTest(point)
        // Every `draggingUpdated` lands here — several a second — so only a real change
        // is worth an update to the island.
        guard zone != targeted else { return zone }
        targeted = zone
        phase = zone.map(StashPhase.targeted) ?? .hovering
        showZones()
        return zone
    }

    /// The cursor left the catcher without dropping: no card is targeted any more, but
    /// the panel stays up until the hot rect's debounce closes it.
    public func catcherExited() {
        guard isZonesShown, targeted != nil else { return }
        targeted = nil
        phase = .hovering
        showZones()
    }

    /// Handles a drop the catcher already read into file URLs.
    ///
    /// AirDrop collapses the island first and hands over after a beat, so the sheet does
    /// not fight the closing animation. A stash drop keeps the panel for the settle card,
    /// then collapses into the peek.
    public func drop(urls: [URL], on zone: Zone) async {
        // The drop the mouse-up was waiting for: whatever happens next, the grace has
        // done its job and must not fire over it. Whether one was pending decides who
        // closes the panel in the branches below that stash nothing — if the button is
        // already up, no later drag event is coming to do it.
        let wasAwaitingDrop = dropGraceToken != nil
        cancelDropGrace()

        // Nothing readable came off the pasteboard: close up as if the drag had simply
        // ended over us (spec §4).
        guard !urls.isEmpty else {
            logger.error("drop on \(zone.rawValue, privacy: .public) carried no files")
            // Nothing is coming, so `.ended` must dismiss rather than arm a second grace
            // on the card the empty drop landed on.
            targeted = nil
            handle(.ended)
            return
        }

        // The previous drag-out is over for good once files land on a card.
        if dragOutPhase == .cancelled { dragOutPhase = .idle }

        switch zone {
        case .airDrop:
            // A drop that landed on a card outlives the drag that armed the leave
            // debounce: the cursor may well have dipped below the hot rect on its way
            // into the card, and that dismiss must not fire behind the hand-over.
            cancelLeave()
            dismissZones()
            phase = .idle
            airDropToken?.cancel()
            airDropToken = clock.schedule(after: Self.airDropDelay) { [weak self] in
                guard let self else { return }
                airDropToken = nil
                _ = airDrop(urls)
            }

        case .stash, .addToStash, .replaceStash:
            // A drag that came out of the stash and went back into it would copy the
            // files onto themselves; the card is drawn as a target so the drag has
            // somewhere harmless to land, and landing there does nothing — beyond
            // closing the panel the grace was holding open for this very drop.
            guard dragOutPhase != .dragging else {
                if wasAwaitingDrop {
                    targeted = nil
                    handle(.ended)
                }
                return
            }
            await stash(urls, action: Self.action(for: zone, default: settings.stashDropAction))
        }
    }

    /// What each card does to the pile: the two explicit cards say so, the main stash
    /// card follows the setting.
    private static func action(for zone: Zone, default fallback: StashDropAction) -> StashDropAction {
        switch zone {
        case .addToStash: .add
        case .replaceStash: .replace
        case .stash, .airDrop: fallback
        }
    }

    private func stash(_ urls: [URL], action: StashDropAction) async {
        // The cursor reached the card through the bottom of the panel, which is outside
        // the shorter hot rect: a leave armed on the way in would otherwise dismiss the
        // settle card mid-animation.
        cancelLeave()
        targeted = nil
        phase = .dropped(pending: urls)
        refreshZones()

        await beforeStash?()
        index = await store.stash(urls, action: action)
        // The feature can be switched off while the copy is in flight. The files still go
        // into the stash — the user dropped them, and the next activation's `loadStash()`
        // will find them — but presenting anything from here would put a card on an island
        // that no longer has a drag observer, a catcher, or any way to take it down.
        guard !isStopped else { return }
        logger.info("""
            stashed \(urls.count, privacy: .public) file(s) by \(action.rawValue, privacy: .public); \
            stash now holds \(self.index.files.count, privacy: .public)
            """)
        phase = .settling
        refreshZones()
        refreshThumbnails()

        settleToken?.cancel()
        // The settle belongs to *this* showing of the panel. If the card it was playing
        // in is gone by the time it fires — dismissed by a later AirDrop drop, replaced
        // by a fresh panel for a new drag — tearing down whatever is on screen now would
        // take someone else's card with it.
        let showing = zonesID
        settleToken = clock.schedule(after: Self.settleDelay) { [weak self] in
            guard let self else { return }
            settleToken = nil
            // The peek and the 24-hour clock belong to the files, not to the panel, so
            // they land either way.
            refreshStash()
            armExpiry()
            guard zonesID == showing else {
                // Somebody else's card is on screen (or none is), so there is nothing here
                // to take down — but the phase is still ours to close. Left at `.settling`
                // it would keep ``isDropInFlight`` true for ever, and every later
                // `.leftHotRect` and `.ended` would be ignored: the panel would come up on
                // the next drag and never come down again.
                if phase == .settling { phase = .stashed }
                return
            }
            dismissZones()
            phase = .stashed
        }
    }

    // MARK: - Drag out

    /// A drag out of the stash started: the panel offers only the stash card for the rest
    /// of it (`ZoneState` derives that from ``dragOutPhase``).
    public func dragOutBegan() {
        dragOutPhase = .dragging
    }

    /// The drag-out session ended. A session that actually delivered files clears the
    /// stash after the poof — Seam's behaviour, and the reason the island moves on to the
    /// next card once files have been taken out of it. A cancelled one leaves it alone.
    ///
    /// ``DragOutPhase/cancelled`` *stays* until the next ``dragOutBegan()`` or drop
    /// rather than hopping straight back to `.idle`: a synchronous round trip would never
    /// be observable, and the distinction is worth keeping (a cancelled drag-out is a
    /// stack that snapped back, an idle one was never dragged). ``zones`` reads only
    /// `.dragging`, so a cancelled phase changes nothing about the panel.
    /// - Parameter files: what the session was carrying. The compact fan drags the whole
    ///   stash (``DragOutScope/all``, the default, and the only thing that empties it); a
    ///   tile in the hover-expanded row drags its own file, and only that file leaves.
    public func dragOutEnded(completed: Bool, files: DragOutScope = .all) {
        guard completed else {
            dragOutPhase = .cancelled
            return
        }
        switch files {
        case .all:
            dragOutPhase = .completed
            poofToken?.cancel()
            poofToken = clock.schedule(after: Self.poofDuration) { [weak self] in
                guard let self else { return }
                poofToken = nil
                poofTask?.cancel()
                poofTask = Task { @MainActor [weak self] in await self?.finishPoof() }
            }

        case let .single(id):
            // Straight back to `.idle` rather than `.completed`: the stash is still there,
            // and `.completed` is what fades the *whole* card away. The tile that left
            // poofs on its own below.
            dragOutPhase = .idle
            poofFile(id: id)
        }
    }

    /// Empties the stash once the receiver actually has the bytes.
    ///
    /// The session reported `.completed` as soon as the receiving application *accepted*
    /// the drop, which for a lazy receiver is long before it asks for the files. Deleting
    /// here without waiting is how the user's only copy disappears (see
    /// ``DragOutPromiseTracker``), so anything still outstanding holds the deletion up to
    /// ``promiseSettleTimeout`` — and the files nobody ever asked for are kept.
    private func finishPoof() async {
        let unredeemed = await settlingPromises.waitUntilSettled(timeout: Self.promiseSettleTimeout)
        guard !Task.isCancelled, !isStopped else { return }

        if unredeemed.isEmpty {
            await clearStash()
        } else {
            logger.error("""
                keeping \(unredeemed.count, privacy: .public) of \
                \(self.index.files.count, privacy: .public) stashed file(s): \
                their promises were never redeemed
                """)
            await deleteRedeemed(keeping: unredeemed)
        }
        guard !Task.isCancelled, !isStopped else { return }
        dragOutPhase = .idle
        poofTask = nil
    }

    /// Takes out everything the receiver really took and leaves the rest of the pile where
    /// it is, card and all.
    private func deleteRedeemed(keeping unredeemed: Set<UUID>) async {
        let taken = index.files.filter { !unredeemed.contains($0.id) }
        for file in taken {
            index = await store.remove(fileID: file.id)
            guard !isStopped else { return }
            thumbnails[file.id] = nil
        }
        guard !index.files.isEmpty else {
            await stashBecameEmpty()
            return
        }
        poofingFileIDs.removeAll()
        refreshStash()
    }

    // MARK: - One file at a time

    /// Fades one tile out and takes that file out of the stash when the fade is over.
    ///
    /// The poof and the removal are two steps because the fade is a *clock* delay: the
    /// island's clock schedules callbacks rather than offering something to await, and
    /// awaiting one through a continuation would strand this work for good the day
    /// ``stop()`` cancelled the timer under it. So the timer lives here and the work it
    /// starts is ``removeFile(id:)``, which is also what a test drives directly when the
    /// fade is not the thing under test.
    ///
    /// Both the "Remove <name>" menu row and a completed single-file drag-out land here.
    public func poofFile(id: UUID) {
        guard index.files.contains(where: { $0.id == id }) else { return }
        // No `refreshStash()`: the row reads ``poofingFileIDs`` off this observable model,
        // so the tile already on screen starts fading where it stands. Re-presenting the
        // card would hand SwiftUI a fresh view mid-animation, which is how a fade turns
        // into a jump — the whole-card poof works the same way.
        poofingFileIDs.insert(id)
        filePoofTokens[id]?.cancel()
        filePoofTokens[id] = clock.schedule(after: Self.poofDuration) { [weak self] in
            guard let self else { return }
            filePoofTokens[id] = nil
            fileRemovalTasks[id]?.cancel()
            fileRemovalTasks[id] = Task { @MainActor [weak self] in
                await self?.removeFile(id: id)
                self?.fileRemovalTasks[id] = nil
            }
        }
    }

    /// Takes one file out of the stash: the copy on disk, the index entry, the thumbnail
    /// and — when it was the last one — the card itself.
    ///
    /// The rest of the pile keeps its card, its id and its 24-hour clock, so the row
    /// closes up around the gap instead of the island collapsing and coming back.
    public func removeFile(id: UUID) async {
        guard index.files.contains(where: { $0.id == id }) else {
            poofingFileIDs.remove(id)
            return
        }
        // The same wait a whole-stash drag-out does: this file may be exactly the one a
        // receiver has accepted and not yet asked for. Costs nothing — one comparison —
        // when nothing is outstanding, which is every menu-driven removal.
        let unredeemed = await settlingPromises.waitUntilSettled(timeout: Self.promiseSettleTimeout)
        guard !isStopped else { return }
        guard !unredeemed.contains(id) else {
            logger.error("keeping a stashed file: the receiver never asked for its bytes")
            // The tile faded out on the way here; it comes back with the card.
            poofingFileIDs.remove(id)
            refreshStash()
            return
        }
        index = await store.remove(fileID: id)
        guard !isStopped else { return }
        poofingFileIDs.remove(id)
        thumbnails[id] = nil
        logger.info("removed one file from the stash; \(self.index.files.count, privacy: .public) left")
        guard index.files.isEmpty else {
            refreshStash()
            return
        }
        // The last file has left: the same teardown a completed whole-stash drag-out does,
        // minus the clearing — `StashStore.remove` has already emptied the index.
        await stashBecameEmpty()
    }

    // MARK: - The stash's lifecycle

    /// Reads the stash from disk at activation and shows it if it survived.
    ///
    /// The read is cancellable: the feature cancels this task in `deactivate`, and a
    /// load that came back afterwards would present a peek for an island that is off.
    public func loadStash() async {
        let loaded = await store.load()
        guard !Task.isCancelled, !isStopped else { return }
        index = loaded
        guard !index.files.isEmpty else { return }
        phase = .stashed
        refreshStash()
        armExpiry()
        refreshThumbnails()
    }

    /// Empties the stash: the copies, the index, the card and the thumbnails.
    public func clearStash() async {
        await store.clear()
        index = StashIndex()
        guard !isStopped else { return }
        await stashBecameEmpty()
    }

    /// Everything that has to happen once the last file is gone, however it went — the
    /// whole stash cleared, expired, or the final tile dragged out on its own.
    private func stashBecameEmpty() async {
        cancelExpiry()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnails.removeAll()
        poofingFileIDs.removeAll()
        await thumbnailProvider.clearCache()
        guard !isStopped else { return }
        dismissStash()
        // A panel still up would now be drawing an empty stash.
        if isZonesShown, zones.isEmpty { dismissZones() }
        if phase == .stashed { phase = .idle }
    }

    /// Opens the stash folder in Finder ("Reveal stash in Finder" — our addition, not Seam's).
    public func revealStash() {
        let directory = store.stashDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            // Nothing has ever been stashed, so `Stash/` does not exist yet: show the
            // folder it will appear in rather than failing silently.
            let parent = directory.deletingLastPathComponent()
            if !NSWorkspace.shared.open(parent) {
                logger.error("could not reveal the stash: neither it nor its parent exists")
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Settings

    public func toggleAirDrop() {
        settings.airdrop.toggle()
        refreshZones()
    }

    public func toggleStashZone() {
        settings.stash.toggle()
        refreshZones()
    }

    public func toggleSecondZone() {
        settings.secondZone.toggle()
        refreshZones()
    }

    public func setStashDropAction(_ action: StashDropAction) {
        settings.stashDropAction = action
        refreshZones()
    }

    // MARK: - Teardown

    /// Drops both presentations and every timer. Called when the feature is switched off.
    public func stop() {
        // First, so that anything already suspended on an `await` finds it set the moment
        // it resumes and bails out instead of presenting into a dead island.
        isStopped = true
        cancelLeave()
        cancelDropGrace()
        settleToken?.cancel()
        settleToken = nil
        airDropToken?.cancel()
        airDropToken = nil
        poofToken?.cancel()
        poofToken = nil
        for token in filePoofTokens.values { token.cancel() }
        filePoofTokens.removeAll()
        for task in fileRemovalTasks.values { task.cancel() }
        fileRemovalTasks.removeAll()
        poofingFileIDs.removeAll()
        cancelExpiry()
        // The tokens only cancel the *timers*; the work a fired timer handed to an actor
        // is a `Task` of its own and has to be cancelled too.
        poofTask?.cancel()
        poofTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnails.removeAll()
        // Before `dismissZones()`, so the dismiss below cannot arm a countdown on a
        // feature that is being switched off; the mirror goes back at once instead.
        cancelMirrorRelease()
        dismissZones()
        dismissStash()
        releaseMirror()
        phase = .idle
        dragOutPhase = .idle
    }

    // MARK: - The zones presentation

    private func showZones() {
        let id = zonesID ?? PresentationID()
        let isNewShowing = zonesID == nil
        if isNewShowing {
            zonesID = id
            isZonesShown = true
            // The catcher goes up first, before the SwiftUI card is built and presented:
            // see ``onCatcherFrameChange``. Presenting is the most expensive thing that
            // happens during a drag, and a window ordered in after it can miss the drop.
            onCatcherFrameChange?(catcherFrameNeeded)
        }
        let presentation = Presentation(
            id: id,
            featureID: Self.featureID,
            title: Self.displayTitle,
            priority: .alert,
            style: .expanded,
            leading: AnyView(EmptyView()),
            trailing: AnyView(EmptyView()),
            expanded: viewFactory.zones(self),
            expandedSize: Self.zonesSize,
            // No dots over the cards: the panel is not a page of the stack, it is a
            // target for the drag in the user's hand, and Seam shows none there either.
            showsStackDots: false
        )
        if isNewShowing {
            islandPresenter.present(presentation)
        } else {
            islandPresenter.update(presentation)
        }
    }

    /// Rebuilds the panel in place; a no-op when it is not on screen, so state changes
    /// that happen while idle never open it.
    private func refreshZones() {
        guard zonesID != nil else { return }
        showZones()
    }

    private func dismissZones() {
        targeted = nil
        guard let zonesID else { return }
        islandPresenter.dismiss(zonesID)
        self.zonesID = nil
        isZonesShown = false
        // Nothing to catch for any more; `catcherFrameNeeded` is `nil` from here.
        onCatcherFrameChange?(catcherFrameNeeded)
        // Only when the drag itself is already over: a panel dismissed by the leave
        // debounce is one the user may well drag back into, and swapping the windows
        // mid-drag would put the thumbnail back behind the island.
        if isMirrorReleasePending { scheduleMirrorRelease() }
    }

    private func cancelLeave() {
        leaveToken?.cancel()
        leaveToken = nil
    }

    // MARK: - The stash presentation

    /// Presents or updates the peek, and dismisses it once the stash is empty. One id for
    /// as long as files exist, so adding to the stash grows the stack rather than
    /// replacing the card.
    private func refreshStash() {
        guard !index.files.isEmpty else {
            dismissStash()
            return
        }
        let presentation = Presentation(
            id: stashID ?? PresentationID(),
            featureID: Self.featureID,
            title: Self.displayTitle,
            priority: .background,
            style: .peek,
            leading: viewFactory.stashLeading(self),
            trailing: viewFactory.stashTrailing(self),
            expanded: viewFactory.stashExpanded(self),
            expandedSize: Self.stashExpandedSize
        )
        if stashID == nil {
            stashID = presentation.id
            islandPresenter.present(presentation)
        } else {
            islandPresenter.update(presentation)
        }
    }

    private func dismissStash() {
        guard let stashID else { return }
        islandPresenter.dismiss(stashID)
        self.stashID = nil
    }

    // MARK: - Thumbnails

    /// Fills ``thumbnails`` for anything new and forgets anything that has left the stash,
    /// then refreshes the card so the stack redraws.
    ///
    /// One task at a time: a second drop while the first batch is still generating cancels
    /// it, and the fresh index is a superset of what was wanted anyway.
    private func refreshThumbnails() {
        thumbnailTask?.cancel()
        let files = index.files
        thumbnailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for file in files where thumbnails[file.id] == nil {
                let thumbnail = await thumbnailProvider.thumbnail(for: URL(fileURLWithPath: file.storedPath))
                guard !Task.isCancelled else { return }
                thumbnails[file.id] = thumbnail
            }
            guard !Task.isCancelled else { return }
            let live = Set(files.map(\.id))
            thumbnails = thumbnails.filter { live.contains($0.key) }
            thumbnailTask = nil
            refreshStash()
        }
    }

    // MARK: - Expiry

    /// Arms the one-shot that clears the stash when its 24 hours are up. Nothing is armed
    /// for an empty stash, which is what keeps the idle cost at zero timers (spec §5).
    private func armExpiry() {
        cancelExpiry()
        guard let stashedAt = index.stashedAt, !index.files.isEmpty else { return }
        let remaining = max(0, StashIndex.ttl - now().timeIntervalSince(stashedAt))
        expiryToken = clock.schedule(after: .seconds(remaining)) { [weak self] in
            guard let self else { return }
            expiryToken = nil
            logger.info("stash expired after \(StashIndex.ttl, privacy: .public) s")
            expiryTask?.cancel()
            expiryTask = Task { @MainActor [weak self] in await self?.clearStash() }
        }
    }

    private func cancelExpiry() {
        expiryToken?.cancel()
        expiryToken = nil
    }
}
