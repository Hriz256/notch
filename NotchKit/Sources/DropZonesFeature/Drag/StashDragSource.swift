import AppKit
import DropZonesShared
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - The SwiftUI wrapper

/// Turns the view it is laid over into the source of a file drag carrying the whole stash.
///
/// SwiftUI's own `.draggable` cannot do this: it offers one item per view and no file
/// promises, whereas dragging the stash out has to hand the receiver *n* real files whose
/// bytes are only copied if the drop is accepted.
///
/// It is an invisible **overlay** rather than a host for the thumbnails, which keeps the
/// pixels under it pure SwiftUI: they stay crisp, they stay measurable by the render
/// tests, and the right-click menu attached to them still opens — the overlay claims the
/// left button and declines every other event (see ``DragSourceView/hitTest(_:)``).
struct StashDragSource: NSViewRepresentable {
    let files: [StashedFile]
    let store: StashStore
    /// Where the session's unredeemed promises are counted, so the stash is not deleted
    /// out from under a receiver that has not asked for the bytes yet.
    let promises: DragOutPromiseTracker
    let onBegan: () -> Void
    let onEnded: (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DragSourceView) {
        view.files = files
        view.store = store
        view.promises = promises
        view.onBegan = onBegan
        view.onEnded = onEnded
    }
}

// MARK: - The AppKit source

/// The `NSDraggingSource` behind the stash's thumbnails.
///
/// It starts the session by hand rather than through `NSView.dragFile` or a drag gesture
/// because all three of the things that make the drag-out correct — one promise per file,
/// the cascade of icons, and the operation mask that differs inside and outside the app —
/// are only expressible on `beginDraggingSession`.
final class DragSourceView: NSView, NSDraggingSource {
    var files: [StashedFile] = []
    var store: StashStore?
    var promises: DragOutPromiseTracker?
    var onBegan: () -> Void = {}
    var onEnded: (Bool) -> Void = { _ in }

    /// How far the pointer must travel before a press becomes a drag. Below it the gesture
    /// is a click, and the island's tap-to-expand must still work through the thumbnails.
    static let dragThreshold: CGFloat = 4
    /// The drag image: one file icon per item, at the size Finder uses for a drag.
    static let iconSide: CGFloat = 32

    private var mouseDownPoint: NSPoint?

    /// Flipped so that the y axis runs the way the spec's cascade is written.
    ///
    /// `NSDraggingItem.setDraggingFrame(_:contents:)` takes a rect in *this* view's
    /// coordinate system, and an ordinary `NSView` is y-up, where the spec's
    /// `(4·i, −4·i)` would step each icon right and *down*-screen — the opposite of the
    /// fan the reference recording shows. Flipping the view makes −y up-screen, so the
    /// one set of offsets in `DragOutPolicy` reads correctly here and in the SwiftUI
    /// stack it is drawn to match.
    override var isFlipped: Bool { true }

    // MARK: Mouse

    /// The island is a non-activating panel: without this the first click after the app
    /// loses focus would be swallowed activating us, and the user would have to press
    /// twice to start a drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Left-button events are ours — they are what starts the drag. Everything else, the
    /// right-click that opens the context menu above all, is declined so it reaches the
    /// SwiftUI content underneath: an overlay that answered every hit test would make the
    /// thumbnails the one part of the island with no menu on it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        // Passed up the responder chain rather than swallowed. It does *not* reach the
        // SwiftUI content under this overlay: that content never saw the matching
        // `mouseDown` — we claimed it in `hitTest` so the drag could start — and
        // SwiftUI's tap gesture needs the pair. A press on the thumbnails that never
        // became a drag is therefore inert, while the island's own tap-to-expand still
        // works everywhere around them.
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !files.isEmpty else { return }
        let travelled = hypot(
            event.locationInWindow.x - start.x,
            event.locationInWindow.y - start.y
        )
        guard travelled >= Self.dragThreshold else { return }
        mouseDownPoint = nil
        beginDrag(with: event)
    }

    private func beginDrag(with event: NSEvent) {
        guard let store, let promises else { return }
        // One delegate for the whole session; every provider holds it strongly, because
        // `NSFilePromiseProvider.delegate` is weak and the promises are written long
        // after this method — and after the session — has returned.
        let delegate = StashFilePromiseDelegate(store: store, promises: promises)

        let origin = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = files.enumerated().map { index, file in
            let provider = StashFilePromiseProvider(
                file: file,
                fileType: Self.fileType(for: file),
                delegate: delegate
            )
            let item = NSDraggingItem(pasteboardWriter: provider)

            let icon = NSWorkspace.shared.icon(forFile: file.storedPath)
            icon.size = NSSize(width: Self.iconSide, height: Self.iconSide)
            // The cascade steps right and up-screen per item (`DragOutPolicy`), measured
            // from the pointer so the stack is under the cursor rather than at the view's
            // corner. `−4` is up because this view is flipped; see `isFlipped`.
            let offset = DragOutPolicy.dragImageOffset(index: index)
            item.setDraggingFrame(
                CGRect(
                    x: origin.x - Self.iconSide / 2 + offset.x,
                    y: origin.y - Self.iconSide / 2 + offset.y,
                    width: Self.iconSide,
                    height: Self.iconSide
                ),
                contents: icon
            )
            return item
        }

        guard !items.isEmpty else { return }
        // The session is going ahead, so from this moment every one of those promises is
        // owed to somebody. Registered here rather than as each provider is built, so a
        // session that is abandoned before it starts leaves nothing outstanding — and
        // registered *before* `beginDraggingSession`, which is what makes the count
        // impossible to read too late (the drop can be accepted inside that call).
        for file in files { promises.register(fileID: file.id) }
        beginDraggingSession(with: items, event: event, source: self)
    }

    /// The UTI the promise advertises. Falling back to `public.data` rather than refusing
    /// keeps an extensionless file draggable — the receiver gets bytes and a name, which is
    /// all Finder needs.
    static func fileType(for file: StashedFile) -> String {
        let ext = (file.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "public.data" }
        return type.identifier
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        NSDragOperation(
            rawValue: DragOutPolicy.operationMask(insideApplication: context == .withinApplication)
        )
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // What stops the zones panel from offering the user their own files back: the view
        // model's `dragOutPhase` drives `ZoneState.isDragOut`, and it must be set before
        // the first `draggingUpdated` reaches the catcher.
        onBegan()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Nothing about the promises is torn down here. Finder enqueues
        // `receivePromisedFiles` asynchronously, so this routinely runs *before* a single
        // byte has been written; the providers on the pasteboard own the delegate and
        // keep it alive for exactly as long as the promises can still be redeemed — and
        // ``DragOutPromiseTracker`` is what stops the view model deleting the files out
        // from under a receiver that has not asked for them yet.
        //
        // An empty operation is a cancelled drag — released over nothing, or over something
        // that refused it — and the stash must survive that untouched.
        onEnded(operation != [])
    }
}

// MARK: - Promises

/// A promise that remembers which stashed file it is for, and keeps its delegate alive.
///
/// `NSFilePromiseProvider` hands its delegate nothing but itself, and one delegate serves
/// every item in the session, so the file has to ride along on the provider — as a `let`,
/// so that the value the promise queue reads is the one the main actor wrote.
///
/// The `delegateStrong` reference is the load-bearing part: `NSFilePromiseProvider.delegate`
/// is **weak**, and the bytes are written when the receiver redeems the promise, which can
/// be long after the dragging session ended (Finder queues the copy). The pasteboard owns
/// the provider for as long as the promise stands, so the provider is the right place to
/// anchor the delegate's lifetime — anchoring it to the session instead left the provider
/// delegate-less and the file silently never written.
final class StashFilePromiseProvider: NSFilePromiseProvider {
    let file: StashedFile
    private let delegateStrong: StashFilePromiseDelegate

    /// `super.init()` rather than `super.init(fileType:delegate:)`: AppKit implements the
    /// latter by calling `[self init]`, which in a Swift subclass with stored properties
    /// traps on the `init()` we cannot meaningfully provide. The two properties it would
    /// have set are set here instead, before the provider leaves this method.
    init(file: StashedFile, fileType: String, delegate: StashFilePromiseDelegate) {
        self.file = file
        self.delegateStrong = delegate
        super.init()
        self.fileType = fileType
        self.delegate = delegate
    }
}

/// Writes a stashed file to wherever the receiving application asked for it.
///
/// The work is a file copy off the main actor: `StashStore` is an actor and owns the only
/// code that touches the stash directory, so the delegate does nothing but hand it the
/// destination and pass the result back. `completionHandler` may be called from any queue
/// and at any time, which is what lets the copy be a plain `await`.
final class StashFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let store: StashStore
    /// Where this session's promises are counted off as they are written. The stash is not
    /// deleted while anything here is still outstanding (see ``DragOutPromiseTracker``).
    private let promises: DragOutPromiseTracker
    private let logger = Logger(subsystem: "app.notch", category: "dropzones.dragout")

    /// One shared queue: the promises of a session are written concurrently on it, and it
    /// must not be the main queue — a receiver that asks for several large files would
    /// otherwise block the island while they copy.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.notch.dropzones.dragout"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(store: StashStore, promises: DragOutPromiseTracker) {
        self.store = store
        self.promises = promises
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider as? StashFilePromiseProvider)?.file.name ?? "File"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Anything but our own provider is a programming error, not a drag we can serve;
        // the receiver is told rather than left waiting for bytes that never come.
        guard let file = (filePromiseProvider as? StashFilePromiseProvider)?.file else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let store = store
        let promises = promises
        let logger = logger
        let completion = UncheckedSendable(completionHandler)
        Task {
            var thrown: (any Error)?
            do {
                try await store.write(file: file, to: url)
            } catch {
                // The receiver shows its own error; ours is the only record of *why*, and
                // the stash is deliberately left alone so nothing is lost.
                logger.error("""
                    could not write \(file.name, privacy: .public) to the drop destination: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                thrown = error
            }
            // Settled either way, and *before* the receiver is told: a failed write is
            // still a promise nobody is waiting on any more, and a promise left standing
            // would hold the stash's deletion for the full timeout.
            await promises.settle(fileID: file.id)
            completion.value(thrown)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }
}

/// Carries AppKit's non-`Sendable` completion handler into the copy task.
///
/// `@unchecked Sendable` justification: the handler is called exactly once, from one task,
/// and AppKit documents it as callable from any queue.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
