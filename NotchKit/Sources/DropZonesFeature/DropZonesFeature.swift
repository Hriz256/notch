import AppKit
import DropZonesShared
import Foundation
import IslandCore
import Observation
import os

/// The "Drop Zones" island feature: drag detection, the drop catcher, the stash and the
/// island views.
///
/// The feature is the only place where the pieces meet the running system. Everything it
/// owns is built in ``activate(presenter:)`` and dropped in ``deactivate()``, with one
/// exception: ``settings`` is built in `init`, because the status menu reads and writes it
/// whether or not the island is currently on (same reasoning as `CodeAgentFeature`).
///
/// Wiring, in the order it has to happen:
///
/// - the view model gets a ``panelFrameProvider`` that recomputes the panel's rect from
///   the screen every time it is asked, so a screen that was resized or unplugged between
///   two drags needs no notification plumbing;
/// - the `DragObserver` feeds `handle(_:)` and is handed *to* the model as well, because a
///   drag that started from our own stash must not be offered the stash card again;
/// - the `DropCatcherWindow` is ordered in and out from the model's
///   ``DropZonesViewModel/onCatcherFrameChange``, so the only window that can swallow a
///   drop exists over the notch exactly while the zones are drawn there — and is in place
///   before the panel they are drawn in is presented.
@MainActor
@Observable
public final class DropZonesFeature: IslandFeature {
    public static let featureID = DropZonesViewModel.featureID

    public let id = DropZonesViewModel.featureID

    /// User preferences, shared with the status menu and the island's context menu.
    public let settings: DropZonesSettings

    /// The live view model, or `nil` while the feature is switched off. Exposed because
    /// the status menu's "Clear stash" / "Reveal stash in Finder" rows act on it (and grey
    /// out when there is none).
    public private(set) var model: DropZonesViewModel?

    /// Where the stash lives; injected so tests never touch the user's real one.
    @ObservationIgnored private let baseDirectory: URL
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "dropzones.feature")

    @ObservationIgnored private var observer: DragObserver?
    /// The window that receives the drop, or `nil` while the feature is off. Not private
    /// so the tests can check that it is ordered in with the zones and out with them.
    @ObservationIgnored private(set) var catcher: DropCatcherWindow?
    @ObservationIgnored private var bridge: CatcherBridge?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// `~/Library/Application Support/Notch`, the directory the whole app keeps its state in.
    ///
    /// The fallback is not decoration: `urls(for:in:)` returns an empty array on a system
    /// with no Application Support directory, and a feature that traps there would take the
    /// app down over a stash nobody has used yet.
    public static var defaultBaseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Notch", isDirectory: true)
    }

    /// `<tmp>/app.notch/DragStaging`, where promised and image-only drops are written
    /// before the stash copies them (spec §2 "Reading the drop").
    public static var stagingRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("app.notch/DragStaging", isDirectory: true)
    }

    /// - Parameters:
    ///   - baseDirectory: the stash's parent directory.
    ///   - defaults: where the settings live; injected so tests get a throw-away suite.
    public init(
        baseDirectory: URL = DropZonesFeature.defaultBaseDirectory,
        defaults: UserDefaults = .standard
    ) {
        self.baseDirectory = baseDirectory
        self.settings = DropZonesSettings(defaults: defaults)
    }

    // MARK: - Geometry

    /// Where the zones panel is on screen, in screen coordinates (origin bottom-left).
    ///
    /// Not the island's frame: `IslandLayout` floors the expanded island at the peek width
    /// (notch + 2 × 56), which is wider than the 280 pt panel on every Mac with a notch, so
    /// the panel sits centred inside it with a few points of black either side. The catcher
    /// has to line up with the *cards*, not with the black shape around them.
    ///
    /// Pure and static so it can be checked against the reference geometry without a screen.
    public static func panelFrame(screenFrame: CGRect, notchRect: CGRect) -> CGRect {
        let size = DropZonesViewModel.zonesSize
        return CGRect(
            x: notchRect.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The panel rect for the screen the island is on right now, or `.zero` when there is
    /// no notch to be on (design §4: the feature stays installed and simply never opens).
    private static func currentPanelFrame() -> CGRect {
        guard let geometry = ScreenMetrics.current().flatMap(NotchGeometry.init(metrics:)) else { return .zero }
        return panelFrame(screenFrame: geometry.screenFrame, notchRect: geometry.notchRect)
    }

    // MARK: - Lifecycle

    public func activate(presenter: any IslandPresenting) {
        deactivate()

        let model = DropZonesViewModel(
            presenter: presenter,
            clock: TaskClock(),
            settings: settings,
            store: StashStore(baseDirectory: baseDirectory),
            thumbnails: ThumbnailProvider(size: 48),
            airDrop: { AirDropSender.send($0) },
            viewFactory: Self.viewFactory
        )
        model.panelFrameProvider = { Self.currentPanelFrame() }

        // The hot rect is read per mouse-down rather than captured, for the same reason as
        // the panel frame: the screen can change between two drags.
        let observer = DragObserver(hotRect: { DragObserver.hotRect(for: Self.currentScreenFrame()) })
        observer.onEvent = { [weak model] output, _ in model?.handle(output) }
        model.dragObserver = observer

        let catcher = DropCatcherWindow()
        let bridge = CatcherBridge(model: model, stagingRoot: Self.stagingRoot)
        catcher.catcherView.delegate = bridge
        // Direct and synchronous: the model calls this as the zones go up, in the same
        // main-actor turn, before the panel is presented.
        model.onCatcherFrameChange = { [weak self] frame in self?.setCatcherFrame(frame) }

        self.model = model
        self.observer = observer
        self.catcher = catcher
        self.bridge = bridge

        observer.start()
        loadTask = Task { @MainActor [weak model] in await model?.loadStash() }
        logger.info("Drop Zones feature activated")
    }

    public func deactivate() {
        // `FeatureRegistry` calls this on every master-switch change, including for a
        // feature that was never on, and `activate` calls it to clear the decks — neither
        // is worth a line in the log.
        let wasActive = model != nil
        // The observer goes first: a drag event landing mid-teardown would re-present the
        // panel the view model is about to dismiss.
        observer?.stop()
        observer = nil
        loadTask?.cancel()
        loadTask = nil
        // `hide` orders it out and makes it transparent to the mouse again; `close`
        // releases the window's server-side resources rather than leaving them to the
        // next autorelease (the panel is `isReleasedWhenClosed = false`, so this is safe
        // with the last reference still in hand).
        catcher?.hide()
        catcher?.close()
        catcher = nil
        bridge = nil
        // The copies on disk survive: the stash is the user's, not the session's.
        model?.stop()
        model = nil
        if wasActive { logger.info("Drop Zones feature deactivated") }
    }

    /// The frame of the screen the island lives on, or `.zero` when there is no notch —
    /// `DragObserver.hotRect(for:)` turns that into an empty rect that contains nothing.
    private static func currentScreenFrame() -> CGRect {
        ScreenMetrics.current().flatMap(NotchGeometry.init(metrics:))?.screenFrame ?? .zero
    }

    // MARK: - The catcher window

    /// Orders the catcher in over the panel, or out when there is no panel to catch for.
    ///
    /// Called by the view model as the zones are presented and dismissed — synchronously,
    /// in that same turn (see ``DropZonesViewModel/onCatcherFrameChange``). An empty frame
    /// counts as "out": a machine with no notch has no panel to catch for, and a 40×40
    /// window parked at the screen's origin would be a bug everywhere else on the desktop.
    private func setCatcherFrame(_ frame: CGRect?) {
        guard let catcher else { return }
        guard let frame, !frame.isEmpty else {
            catcher.hide()
            return
        }
        catcher.catcherView.panelFrame = frame
        // A little slack around the panel so a drop that lands a point or two outside a
        // card's edge still reaches the catcher; the hit test is against `panelFrame`, so
        // the extra area answers "no zone" and refuses the drag, exactly as a gap does.
        catcher.show(frame: frame.insetBy(dx: -Self.catcherSlack, dy: -Self.catcherSlack))
    }

    private static let catcherSlack: CGFloat = 20

    // MARK: - Status-menu surface

    /// Menu writes go through the view model while the island is on, so a panel that is on
    /// screen re-derives its cards immediately; straight into `settings` otherwise. The
    /// model only offers toggles, which is why each setter checks first — the guard is what
    /// makes "set to what it already is" a no-op rather than a flip.
    public func setAirDropZone(_ on: Bool) {
        guard settings.airdrop != on else { return }
        if let model { model.toggleAirDrop() } else { settings.airdrop = on }
    }

    public func setStashZone(_ on: Bool) {
        guard settings.stash != on else { return }
        if let model { model.toggleStashZone() } else { settings.stash = on }
    }

    public func setSecondZone(_ on: Bool) {
        guard settings.secondZone != on else { return }
        if let model { model.toggleSecondZone() } else { settings.secondZone = on }
    }

    public func setStashDropAction(_ action: StashDropAction) {
        guard settings.stashDropAction != action else { return }
        if let model { model.setStashDropAction(action) } else { settings.stashDropAction = action }
    }

    /// Whether there is anything to clear or reveal. `true` while the feature is off, which
    /// is what greys those rows out.
    public var stashIsEmpty: Bool { model?.index.files.isEmpty ?? true }

    public func revealStash() { model?.revealStash() }

    public func clearStash() {
        guard let model else { return }
        Task { @MainActor in await model.clearStash() }
    }

    // MARK: - The catcher's delegate

    /// Forwards the catcher window's drag messages to the view model.
    ///
    /// A separate object rather than a conformance on the feature: `DropCatcherView` holds
    /// its delegate weakly and the feature is held by the registry, so this could have been
    /// the feature itself — but the drop path needs the model and the staging root together,
    /// and a bridge that owns both cannot be called with a stale one after a deactivation.
    @MainActor
    private final class CatcherBridge: DropCatcherDelegate {
        private let model: DropZonesViewModel
        private let stagingRoot: URL

        init(model: DropZonesViewModel, stagingRoot: URL) {
            self.model = model
            self.stagingRoot = stagingRoot
        }

        func catcher(_ view: DropCatcherView, targetedAt point: CGPoint) -> Zone? {
            model.targeted(at: point)
        }

        func catcherExited(_ view: DropCatcherView) {
            model.catcherExited()
        }

        /// Reads the payload and hands it to the model.
        ///
        /// `Task.immediate` rather than `Task`: everything `DropPayloadReader` does with the
        /// `NSDraggingInfo` — reading the pasteboard, starting the file-promise receivers —
        /// happens before its first suspension point, and an ordinary `Task` would run that
        /// prefix a main-actor turn *after* `performDragOperation` returned, by which time
        /// the drag and its pasteboard are gone. An immediate task runs it synchronously
        /// here and only suspends for the promise wait and the copy.
        func catcher(_ view: DropCatcherView, dropped info: any NSDraggingInfo, at point: CGPoint) -> Bool {
            // The cursor may have moved since the last `draggingUpdated`, so the drop point
            // decides the card — and a drop between cards is refused rather than guessed at.
            guard let zone = model.targeted(at: point) else { return false }
            let model = model
            let stagingRoot = stagingRoot
            Task.immediate {
                let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: stagingRoot)
                await model.drop(urls: urls, on: zone)
            }
            return true
        }
    }
}
