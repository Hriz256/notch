import CoreGraphics
import Foundation

/// What a drag *out* of the stash offers the receiving app, and how its drag
/// image is stacked.
///
/// This module stays AppKit-free, so the operation mask is an `NSDragOperation`
/// raw value rather than the option set itself; `StashDragSource` wraps it back
/// up with `NSDragOperation(rawValue:)`. The raw values are fixed API constants,
/// and `DragOutPolicyTests` checks them against the real enum.
public enum DragOutPolicy {

    /// `NSDragOperation.copy`.
    public static let copyOperation: UInt = 1
    /// `NSDragOperation([.copy, .generic, .move])` — 1 | 4 | 16.
    public static let inAppOperations: UInt = 21

    /// The source operation mask for a drag-out session.
    ///
    /// Outside the app only `.copy` is offered: the stash holds our own copies of
    /// the user's files and a `.move` would let the receiver delete them behind
    /// our back. Inside the app the wider mask lets our own views accept the drag
    /// under whichever operation they ask for.
    public static func operationMask(insideApplication: Bool) -> UInt {
        insideApplication ? inAppOperations : copyOperation
    }

    /// Where the `index`-th 32×32 icon sits in the cascade, relative to the first.
    ///
    /// Each further icon steps right and up-screen by 4 pt, reading as the fanned-out
    /// stack the thumbnails already draw. `NSDraggingItem.setDraggingFrame(_:contents:)`
    /// takes its rect in the *source view's* coordinates, so "up" here means −y only
    /// because that view is flipped — see `DragSourceView.isFlipped`.
    public static func dragImageOffset(index: Int) -> CGPoint {
        CGPoint(x: 4 * index, y: -4 * index)
    }
}
