import AppKit
import DropZonesShared
import Foundation
import IslandCore
import Observation
import SwiftUI
import os

/// Builds the island views for the Drop Zones feature. Injected so the view model is
/// testable without SwiftUI rendering, exactly like `CodeViewFactory`.
///
/// The zones panel is not in here: it is no longer an island presentation at all, but a
/// view the drop catcher's own window draws (``ZonesPanelView``), built by the feature
/// once at activation rather than per showing.
@MainActor
public struct DropZonesViewFactory {
    /// Peek leading slot: the thumbnail stack.
    public var stashLeading: (DropZonesViewModel) -> AnyView
    /// Peek trailing slot: the file-count circle.
    public var stashTrailing: (DropZonesViewModel) -> AnyView
    /// Hover-expanded stash card: the peek row plus the caption.
    public var stashExpanded: (DropZonesViewModel) -> AnyView

    public init(
        stashLeading: @escaping (DropZonesViewModel) -> AnyView,
        stashTrailing: @escaping (DropZonesViewModel) -> AnyView,
        stashExpanded: @escaping (DropZonesViewModel) -> AnyView
    ) {
        self.stashLeading = stashLeading
        self.stashTrailing = stashTrailing
        self.stashExpanded = stashExpanded
    }

    /// Draws nothing. `Color.clear` rather than `EmptyView` so a placeholder card
    /// still occupies its slot in layout tests.
    public static let placeholder = DropZonesViewFactory(
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
public enum DragOutPhase: Equatable, Sendable {
    case idle
    case dragging
    case completed
    case cancelled
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

/// Turns drag events, drops and the stash on disk into the zones panel and the island's
/// stash card (spec §3.2).
///
/// Two things are on screen, never more:
///
/// - **the zones** — the 280×140 panel, alive only while a drag is over the notch. It is
///   *not* an island presentation: the island's private Space composites above the
///   system's drag image, so a panel drawn there hides the thumbnail in the user's hand.
///   The catcher window draws it instead (``ZonesPanelView``) and the island is
///   suppressed to the bare notch for the duration. This model only says whether it is up
///   (``isZonesShown``) and what is in it; the view observes the rest.
/// - **the stash** — a `.background` peek presented on the island, which lives as long as
///   there are files in the stash and is updated in place as files and thumbnails change.
///
/// The view model owns no windows. `DragObserver` feeds it `handle(_:)`, the catcher
/// window asks it `targeted(at:)` / `drop(urls:on:)`, and it calls
/// ``onCatcherFrameChange`` — synchronously — so the feature can order that window in.
@MainActor
@Observable
public final class DropZonesViewModel {

    // MARK: - Constants

    public static let featureID = FeatureID("dropzones")
    /// What this feature's cards are called in menus.
    public static let displayTitle = "Drop Zones"
    /// The zones panel (spec §2 "Widths").
    public static let zonesSize = CGSize(width: 280, height: 140)
    /// The hover-expanded stash card. Width 0 means "as wide as the peek": `IslandLayout`
    /// widens it, so the card cannot be narrower than the row it grew out of.
    public static let stashExpandedSize = CGSize(width: 0, height: 76)
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
    /// How long the "N Files" settle card plays before the panel collapses.
    public static let settleDelay: Duration = .milliseconds(400)
    /// How long the catcher window stays up after the zones are dismissed.
    ///
    /// The window *is* the panel now, so it has to outlive the collapse it is animating:
    /// the shape starts shrinking back into the notch the moment ``isZonesShown`` flips,
    /// and ordering the window out in that same turn would make the panel disappear
    /// instead. Comfortably longer than the choreographer's 0.38 s collapse spring.
    public static let dismissAnimation: Duration = .milliseconds(450)
    /// The pause between the zones collapsing and the AirDrop sheet appearing.
    public static let airDropDelay: Duration = .milliseconds(300)
    /// The poof after a completed drag-out, before the stash is emptied.
    public static let poofDuration: Duration = .milliseconds(250)

    // MARK: - Published state

    /// What is in the stash right now; the peek and the expanded card are built from it.
    public private(set) var index = StashIndex()
    public private(set) var phase: StashPhase = .idle
    public private(set) var dragOutPhase: DragOutPhase = .idle
    /// The card the cursor is over, `nil` in the gaps and margins.
    public private(set) var targeted: Zone?
    /// Thumbnails by ``StashedFile/id``, filled in the background after the index changes.
    public private(set) var thumbnails: [UUID: Thumbnail] = [:]
    /// Whether the zones panel is up. ``ZonesPanelView`` animates on exactly this: true
    /// grows the black shape out of the notch, false shrinks it back in.
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
    /// The observer a drag *out* of the stash flags for its lifetime, so the panel offers
    /// the stash card alone rather than inviting the user to drop their own files back
    /// where they came from. Set by the feature at activation, and weak because the
    /// feature owns it; `nil` in tests and previews, where no drag can start.
    @ObservationIgnored public weak var dragObserver: DragObserver?

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

    /// Identifies the current *showing* of the panel. A timer armed during one showing
    /// checks it before tearing anything down, so a settle or a grace that belongs to a
    /// drag which is already history cannot close the panel a later drag opened.
    @ObservationIgnored private var showingID: UUID?
    @ObservationIgnored private var stashID: PresentationID?
    @ObservationIgnored private var leaveToken: ScheduledToken?
    @ObservationIgnored private var dropGraceToken: ScheduledToken?
    @ObservationIgnored private var dismissToken: ScheduledToken?
    @ObservationIgnored private var settleToken: ScheduledToken?
    @ObservationIgnored private var airDropToken: ScheduledToken?
    @ObservationIgnored private var poofToken: ScheduledToken?
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
        case .none:
            break

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
        let showing = showingID
        dropGraceToken = clock.schedule(after: Self.dropGrace) { [weak self] in
            guard let self else { return }
            dropGraceToken = nil
            logger.info("no drop arrived within the grace; closing the zones")
            guard showingID == showing, !isDropInFlight else { return }
            dismissZones()
            phase = .idle
        }
    }

    private func cancelDropGrace() {
        dropGraceToken?.cancel()
        dropGraceToken = nil
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
        return zone
    }

    /// The cursor left the catcher without dropping: no card is targeted any more, but
    /// the panel stays up until the hot rect's debounce closes it.
    public func catcherExited() {
        guard isZonesShown, targeted != nil else { return }
        targeted = nil
        phase = .hovering
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

        await beforeStash?()
        index = await store.stash(urls, action: action)
        logger.info("""
            stashed \(urls.count, privacy: .public) file(s) by \(action.rawValue, privacy: .public); \
            stash now holds \(self.index.files.count, privacy: .public)
            """)
        phase = .settling
        refreshThumbnails()

        settleToken?.cancel()
        // The settle belongs to *this* showing of the panel. If the card it was playing
        // in is gone by the time it fires — dismissed by a later AirDrop drop, replaced
        // by a fresh panel for a new drag — tearing down whatever is on screen now would
        // take someone else's card with it.
        let showing = showingID
        settleToken = clock.schedule(after: Self.settleDelay) { [weak self] in
            guard let self else { return }
            settleToken = nil
            // The peek and the 24-hour clock belong to the files, not to the panel, so
            // they land either way.
            refreshStash()
            armExpiry()
            guard showingID == showing else { return }
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
    public func dragOutEnded(completed: Bool) {
        guard completed else {
            dragOutPhase = .cancelled
            return
        }
        dragOutPhase = .completed
        poofToken?.cancel()
        poofToken = clock.schedule(after: Self.poofDuration) { [weak self] in
            guard let self else { return }
            poofToken = nil
            poofTask?.cancel()
            poofTask = Task { @MainActor [weak self] in await self?.finishPoof() }
        }
    }

    private func finishPoof() async {
        await clearStash()
        guard !Task.isCancelled else { return }
        dragOutPhase = .idle
        poofTask = nil
    }

    // MARK: - The stash's lifecycle

    /// Reads the stash from disk at activation and shows it if it survived.
    ///
    /// The read is cancellable: the feature cancels this task in `deactivate`, and a
    /// load that came back afterwards would present a peek for an island that is off.
    public func loadStash() async {
        let loaded = await store.load()
        guard !Task.isCancelled else { return }
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
        cancelExpiry()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnails.removeAll()
        await thumbnailProvider.clearCache()
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

    /// No redraw is asked for: ``zones`` is derived from the settings, which are
    /// `@Observable`, so a panel that is up re-derives its cards on its own.
    public func toggleAirDrop() {
        settings.airdrop.toggle()
    }

    public func toggleStashZone() {
        settings.stash.toggle()
    }

    public func toggleSecondZone() {
        settings.secondZone.toggle()
    }

    public func setStashDropAction(_ action: StashDropAction) {
        settings.stashDropAction = action
    }

    // MARK: - Teardown

    /// Drops both presentations and every timer. Called when the feature is switched off.
    public func stop() {
        cancelLeave()
        cancelDropGrace()
        settleToken?.cancel()
        settleToken = nil
        airDropToken?.cancel()
        airDropToken = nil
        poofToken?.cancel()
        poofToken = nil
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
        // The catcher goes out in this same turn rather than after the collapse: there is
        // nobody left to watch the animation, and the feature is closing the window.
        dismissZones(animated: false)
        dismissStash()
        // Unconditional, unlike `dismissZones`'s own call: a feature switched off with no
        // panel up must still not leave the island hidden.
        islandPresenter.setSurfaceSuppressed(false)
        phase = .idle
        dragOutPhase = .idle
    }

    // MARK: - The zones panel

    /// Puts the panel up: the island goes down to the bare notch and the catcher window —
    /// which is what actually draws the cards — comes up over it.
    ///
    /// Idempotent. Every later change inside one showing (targeting a card, a drop
    /// settling, a card switched off in the menu) reaches the view through observation,
    /// so there is nothing to re-present.
    private func showZones() {
        // A drag arriving inside the 450 ms the window is held open for the last one's
        // collapse re-uses that window rather than watching it vanish under the cursor.
        cancelDismissHold()
        guard !isZonesShown else { return }
        showingID = UUID()
        isZonesShown = true
        // Before the window goes up, so the island is already out of the way in the frame
        // the panel first appears in.
        islandPresenter.setSurfaceSuppressed(true)
        // Synchronous, in this same turn: the catcher's frame contains the whole hot
        // rect, so by the time the window appears the cursor is usually already inside
        // it — and AppKit only picks a drag's destination when the drag *moves*. A window
        // ordered in a turn later would miss a cursor that entered the notch and stopped.
        onCatcherFrameChange?(catcherFrameNeeded)
    }

    /// Takes the panel down. The shape starts shrinking into the notch at once and the
    /// island grows back out of it — both black, both over the notch, so the hand-over
    /// is invisible — and the window that draws the shrinking shape follows it out one
    /// ``dismissAnimation`` later.
    ///
    /// - Parameter animated: `false` orders the window out in this same turn. Teardown
    ///   only: there is nobody left to watch the collapse.
    private func dismissZones(animated: Bool = true) {
        targeted = nil
        cancelDismissHold()
        guard isZonesShown else { return }
        isZonesShown = false
        showingID = nil
        islandPresenter.setSurfaceSuppressed(false)
        guard animated else {
            onCatcherFrameChange?(nil)
            return
        }
        dismissToken = clock.schedule(after: Self.dismissAnimation) { [weak self] in
            guard let self else { return }
            dismissToken = nil
            // Nothing to catch for any more; `catcherFrameNeeded` has been `nil` since
            // the flag flipped.
            onCatcherFrameChange?(nil)
        }
    }

    private func cancelDismissHold() {
        dismissToken?.cancel()
        dismissToken = nil
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
