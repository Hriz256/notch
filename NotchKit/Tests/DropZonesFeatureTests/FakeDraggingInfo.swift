import AppKit

/// A stand-in for the `NSDraggingInfo` AppKit hands `performDragOperation`.
///
/// There is no way to make a real one: AppKit creates it inside a live drag
/// session, which an automated test cannot start. Everything the production code
/// actually reads is here — the pasteboard and the dragging location — and the
/// rest of the protocol is answered with the most inert value that compiles, so
/// that a future use of one of them fails loudly in a test rather than quietly in
/// a drag.
///
/// The pasteboard is a private, uniquely named one: tests must never write to the
/// real `.drag` pasteboard, which belongs to whatever the user is doing.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = NSPasteboard(name: .init(UUID().uuidString))) {
        self.pasteboard = pasteboard
        pasteboard.clearContents()
        super.init()
    }

    /// A uniquely named pasteboard is a global pasteboard server object that
    /// outlives the process unless it is released, so every fake takes its own
    /// back down. (A caller-supplied pasteboard is released too — no test passes
    /// one it wants to keep.)
    deinit {
        pasteboard.releaseGlobally()
    }

    /// In the destination window's coordinates, origin bottom-left — the one
    /// value besides the pasteboard that the catcher view reads.
    var draggingLocation: NSPoint = .zero

    var draggingPasteboard: NSPasteboard { pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    // Deprecated, and inherited from `NSObject`'s own dragging category.
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
