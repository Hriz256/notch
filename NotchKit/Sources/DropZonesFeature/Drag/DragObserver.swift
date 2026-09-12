import AppKit
import DropZonesShared
import os

/// Whether a drag pasteboard is carrying something we would take.
///
/// The drag pasteboard's *type list* is the only thing cheap enough to read on
/// every mouse-dragged event — actually reading the items is an IPC decode, and
/// this runs while the user is dragging. The list is also all we need: every
/// payload the drop zones accept announces itself with one of these types.
///
/// The Chrome entry is not decoration. Chrome (and every Electron app) puts
/// nothing but `org.chromium.chromium-initiated-drag` on the pasteboard at drag
/// start and fills the real types later, so without it a Chrome drag looks like
/// an empty pasteboard for the whole approach to the notch.
public enum DragPasteboardClassifier {

    /// Promise types, computed once: `readableDraggedTypes` is a class property
    /// on `NSFilePromiseReceiver` and this is asked on a hot path.
    private static let promiseTypes: Set<NSPasteboard.PasteboardType> = Set(
        NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:))
    )

    /// Everything that counts as file content, as a set so the check is a hash
    /// lookup per advertised type rather than a scan.
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = promiseTypes.union([
        .fileURL,
        // A dragged image has no file at all; `DropPayloadReader` writes it out.
        .png,
        .tiff,
        NSPasteboard.PasteboardType("org.chromium.chromium-initiated-drag"),
    ])

    /// True when `types` says the drag carries files, promised files or image data.
    ///
    /// Note what is *not* here: `.URL` and `.string`. A dragged link or selection
    /// must leave the island alone, even though the catcher registers `.URL` so
    /// that a file URL arriving under that type is still accepted at the drop.
    public static func hasFileContent(types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { fileTypes.contains($0) }
    }
}

/// Watches the whole desktop for a file drag approaching the notch.
///
/// macOS tells no application when *another* application starts a drag, so the
/// only way to notice one is Seam's: four global `NSEvent` monitors plus the
/// drag pasteboard. The grammar — when a gesture becomes a content drag, when it
/// enters and leaves the hot rect — lives in ``DragDetector``; this type is the
/// AppKit plumbing around it and nothing else, which is what keeps the rules
/// testable without a trackpad.
///
/// Cost while the user is not dragging: handlers that compare an `Int` and
/// return (design §5). The pasteboard's *type list* is read only while the detector is
/// still waiting for content, so a long drag past the notch costs one
/// `changeCount` round trip per mouse-move and nothing else.
@MainActor
public final class DragObserver {

    /// Every crossing the detector reports, with the cursor's screen location at
    /// that moment (origin bottom-left) — the view model needs it to decide which
    /// screen the zones belong on.
    ///
    /// The location is real only for the outputs that come from a mouse-*dragged*
    /// event — `.enteredHotRect` and `.leftHotRect`, the two that need it. `.ended`
    /// and `.cancelled` report `.zero`, because reading `NSEvent.mouseLocation` is
    /// a WindowServer round trip and those events fire on an idle machine (design
    /// §5: nothing but an `Int` comparison until a mouse-down).
    public var onEvent: ((DragDetector.Output, CGPoint) -> Void)?

    /// Set by `StashDragSource` for the life of a drag that started from our own
    /// stash. The view model shows only the stash zone for those, so that dragging
    /// files out and letting go near the notch is a no-op rather than a re-stash.
    public var isDragOutActive = false

    private let hotRect: @MainActor () -> CGRect
    private let pasteboard: NSPasteboard
    private var detector = DragDetector(hotRect: .zero)
    private var monitors: [Any] = []
    private let logger = Logger(subsystem: "app.notch", category: "dropzones.drag")

    public init(
        hotRect: @escaping @MainActor () -> CGRect,
        pasteboard: NSPasteboard = NSPasteboard(name: .drag)
    ) {
        self.hotRect = hotRect
        self.pasteboard = pasteboard
    }

    // MARK: - The hot rect

    /// Seam's trigger region for `screenFrame`: 300 pt wide, hugging the top edge,
    /// horizontally centred (screen coordinates, origin bottom-left).
    ///
    /// The nominal rect `(midX − 150, maxY − 120, 300, 220)` reaches a hundred
    /// points above the glass, so it is clipped to the screen — and then extended
    /// by exactly one point upwards. That last point matters: `CGRect.contains`
    /// (what ``DragDetector`` uses) is half-open, so a rect ending at `maxY`
    /// excludes the very row of coordinates the cursor occupies when the user
    /// shoves it up into the notch, which is the gesture the feature exists for.
    ///
    /// An empty or disjoint screen frame gives an empty rect, which contains
    /// nothing: with no notch screen the observer stays installed and the zones
    /// simply never open (design §4).
    public static func hotRect(for screenFrame: CGRect) -> CGRect {
        let nominal = CGRect(
            x: screenFrame.midX - 150,
            y: screenFrame.maxY - 120,
            width: 300,
            height: 220
        )
        let clipped = nominal.intersection(screenFrame)
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        return CGRect(
            x: clipped.minX,
            y: clipped.minY,
            width: clipped.width,
            height: clipped.height + 1
        )
    }

    // MARK: - Lifecycle

    /// The four event types Seam watches, each registered on its own.
    ///
    /// One monitor per mask rather than one monitor for all four, because
    /// `.flagsChanged` is a *key*-related event: a global monitor for it may be
    /// refused when the app is not trusted for Accessibility, and Notch asks for
    /// no such permission. Registered separately, that refusal costs only the
    /// modifier-cancels-the-drag nicety; folded into one mask it could take the
    /// mouse events — the whole feature — down with it.
    private static let monitoredMasks: [NSEvent.EventTypeMask] = [
        .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged,
    ]

    /// Installs the four monitors, globally and locally.
    ///
    /// Global monitors see events delivered to *other* applications; local ones
    /// see our own. The spike showed a drag that starts inside one of our windows
    /// still reaching the global handler, but a drag out of the stash is the one
    /// case where that would be catastrophic to get wrong, so both are installed
    /// and the detector is fed from both. Double delivery is harmless by
    /// construction: a repeated `.mouseDown` re-snapshots the same change count, a
    /// repeated `.dragged` reports the same side of the hot rect and returns
    /// `.none`, and a repeated `.mouseUp` finds the machine already idle.
    public func start() {
        guard monitors.isEmpty else { return }

        for mask in Self.monitoredMasks {
            let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                // Global mouse monitors are delivered on the main run loop, so
                // this is sound — and it avoids the per-mouse-move `Task`
                // allocation (and the reordering that comes with it) that a hop
                // would cost.
                MainActor.assumeIsolated { self?.handle(event) }
            }
            let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
            monitors.append(contentsOf: [global, local].compactMap { $0 })
        }
        logger.debug("drag monitors installed: \(self.monitors.count, privacy: .public)/8")
    }

    /// How many monitors are installed: 8 while running, 0 when stopped. Exposed
    /// for the lifecycle test, which is the only thing about `start()`/`stop()`
    /// that can be checked without a trackpad.
    public var monitorCount: Int { monitors.count }

    /// Removes every monitor and forgets the gesture in flight. Safe to call twice.
    ///
    /// `isDragOutActive` is reset too: it is set by `StashDragSource` for the life
    /// of one drag out of the stash, and a stop mid-drag (the feature being
    /// disabled, the island going away) would otherwise leave it latched `true`
    /// forever, permanently hiding every zone but the stash.
    public func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        detector = DragDetector(hotRect: .zero)
        isDragOutActive = false
    }

    /// The monitors are process-wide: `NSEvent` keeps them alive with no reference
    /// to us, so an observer that is simply dropped would leave eight handlers
    /// running for the rest of the session (each a no-op through the `weak self`,
    /// but each still a delivered event). `isolated deinit` (SE-0371) lets the
    /// teardown run on the main actor, where `stop()` lives.
    isolated deinit {
        stop()
    }

    // MARK: - Events

    /// One monitored event, at the cost the design budgets for it.
    ///
    /// `NSEvent.mouseLocation` is a WindowServer round trip, so it is read *only*
    /// in the two branches whose outputs carry it. `.flagsChanged` in particular
    /// fires whenever the user so much as taps ⌘ with no drag anywhere, and it is
    /// delivered to eight monitors; reading the cursor there would spend the whole
    /// idle budget on an answer nobody looks at.
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // A fresh detector per press: the hot rect is two `CGRect`s of
            // arithmetic, and re-reading it here is what makes the feature follow
            // a screen that was resized, rearranged or unplugged since the last
            // drag without any notification plumbing.
            detector = DragDetector(hotRect: hotRect())
            // `.mouseDown` is always `.none`, so the location is never used.
            emit(detector.receive(.mouseDown(changeCount: pasteboard.changeCount)), at: .zero)

        case .leftMouseDragged:
            let location = NSEvent.mouseLocation
            emit(
                detector.receive(
                    .dragged(
                        changeCount: pasteboard.changeCount,
                        hasFiles: hasFileContent(),
                        location: location
                    )
                ),
                at: location
            )

        case .leftMouseUp:
            emit(detector.receive(.mouseUp), at: .zero)

        case .flagsChanged:
            emit(detector.receive(.flagsChanged), at: .zero)

        default:
            break
        }
    }

    /// The pasteboard's type list, but only while it can still change the answer.
    ///
    /// Once the detector has left `.mouseDown` the content question is settled —
    /// either it promoted to `dragging` or the gesture is over — and reading
    /// `types` on every further mouse-move would add an IPC round trip per event
    /// for an answer nobody looks at.
    private func hasFileContent() -> Bool {
        guard case .mouseDown = detector.phase else { return false }
        return DragPasteboardClassifier.hasFileContent(types: pasteboard.types ?? [])
    }

    private func emit(_ output: DragDetector.Output, at location: CGPoint) {
        guard output != .none else { return }
        logger.debug("\(String(describing: output), privacy: .public)")
        onEvent?(output, location)
    }
}
