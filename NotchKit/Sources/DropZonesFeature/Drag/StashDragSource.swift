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
/// bytes are only copied if the drop is accepted — and has to tell `DragObserver` that the
/// drag in flight is ours, so the zones panel offers the stash card alone instead of
/// inviting the user to drop their own files back where they came from.
///
/// It is an invisible **overlay** rather than a host for the thumbnails, which keeps the
/// pixels under it pure SwiftUI: they stay crisp, they stay measurable by the render
/// tests, and the right-click menu attached to them still opens — the overlay claims the
/// left button and declines every other event (see ``DragSourceView/hitTest(_:)``).
struct StashDragSource: NSViewRepresentable {
    let files: [StashedFile]
    let store: StashStore
    /// Weakly held by the view; `nil` in previews and render tests, where no drag can start.
    let observer: DragObserver?
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
        view.observer = observer
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
    weak var observer: DragObserver?
    var onBegan: () -> Void = {}
    var onEnded: (Bool) -> Void = { _ in }

    /// How far the pointer must travel before a press becomes a drag. Below it the gesture
    /// is a click, and the island's tap-to-expand must still work through the thumbnails.
    static let dragThreshold: CGFloat = 4
    /// The drag image: one file icon per item, at the size Finder uses for a drag.
    static let iconSide: CGFloat = 32

    private var mouseDownPoint: NSPoint?

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
        // A press that never became a drag is a click on the island, which expands it.
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
        guard let store else { return }
        let delegate = StashFilePromiseDelegate(store: store)
        // Kept alive for the session: `NSFilePromiseProvider` holds its delegate weakly,
        // and the promise is written long after this method returns.
        promiseDelegate = delegate

        let origin = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = files.enumerated().map { index, file in
            let provider = StashFilePromiseProvider(fileType: Self.fileType(for: file), delegate: delegate)
            provider.file = file
            let item = NSDraggingItem(pasteboardWriter: provider)

            let icon = NSWorkspace.shared.icon(forFile: file.storedPath)
            icon.size = NSSize(width: Self.iconSide, height: Self.iconSide)
            // The cascade steps right and up per item (`DragOutPolicy`), measured from the
            // pointer so the stack is under the cursor rather than at the view's corner.
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
        beginDraggingSession(with: items, event: event, source: self)
    }

    /// Strong reference for the life of one session; see `beginDrag`.
    private var promiseDelegate: StashFilePromiseDelegate?

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
        // The observer is what stops the zones panel from offering the user their own files
        // back; it must be set before the first `draggingUpdated` reaches the catcher.
        observer?.isDragOutActive = true
        onBegan()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        observer?.isDragOutActive = false
        promiseDelegate = nil
        // An empty operation is a cancelled drag — released over nothing, or over something
        // that refused it — and the stash must survive that untouched.
        onEnded(operation != [])
    }
}

// MARK: - Promises

/// A promise that remembers which stashed file it is for.
///
/// `NSFilePromiseProvider` hands its delegate nothing but itself, and one delegate serves
/// every item in the session, so the file has to ride along on the provider.
final class StashFilePromiseProvider: NSFilePromiseProvider {
    /// Set immediately after `init`, on the main actor, and only read afterwards.
    nonisolated(unsafe) var file: StashedFile?
}

/// Writes a stashed file to wherever the receiving application asked for it.
///
/// The work is a file copy off the main actor: `StashStore` is an actor and owns the only
/// code that touches the stash directory, so the delegate does nothing but hand it the
/// destination and pass the result back. `completionHandler` may be called from any queue
/// and at any time, which is what lets the copy be a plain `await`.
final class StashFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let store: StashStore
    private let logger = Logger(subsystem: "app.notch", category: "dropzones.dragout")

    /// One shared queue: the promises of a session are written concurrently on it, and it
    /// must not be the main queue — a receiver that asks for several large files would
    /// otherwise block the island while they copy.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.notch.dropzones.promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(store: StashStore) {
        self.store = store
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider as? StashFilePromiseProvider)?.file?.name ?? "File"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let file = (filePromiseProvider as? StashFilePromiseProvider)?.file else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let store = store
        let logger = logger
        let completion = UncheckedSendable(completionHandler)
        Task {
            do {
                try await store.write(file: file, to: url)
                completion.value(nil)
            } catch {
                // The receiver shows its own error; ours is the only record of *why*, and
                // the stash is deliberately left alone so nothing is lost.
                logger.error("""
                    could not write \(file.name, privacy: .public) to the drop destination: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                completion.value(error)
            }
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
