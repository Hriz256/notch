import AppKit
import Testing
@testable import DropZonesShared

/// `DropZonesShared` is AppKit-free, so the policy speaks in `NSDragOperation` raw
/// values. These tests are the seam that proves the raw values still mean what the
/// feature module will read them as — they import AppKit so the constants are
/// checked against the real enum rather than against themselves.
@Suite struct DragOutPolicyTests {

    // MARK: - Operation mask

    @Test func draggingOutsideTheAppOffersCopyOnly() {
        #expect(DragOutPolicy.operationMask(insideApplication: false) == 1)
        #expect(DragOutPolicy.operationMask(insideApplication: false) == NSDragOperation.copy.rawValue)
    }

    @Test func draggingInsideTheAppAlsoOffersGenericAndMove() {
        #expect(DragOutPolicy.operationMask(insideApplication: true) == 21)
        let expected: NSDragOperation = [.copy, .generic, .move]
        #expect(DragOutPolicy.operationMask(insideApplication: true) == expected.rawValue)
    }

    @Test func theInsideMaskIsASupersetOfTheOutsideMask() {
        let outside = DragOutPolicy.operationMask(insideApplication: false)
        let inside = DragOutPolicy.operationMask(insideApplication: true)
        #expect(inside & outside == outside)
    }

    // MARK: - Drag image cascade

    @Test func theFirstDragImageSitsAtTheOrigin() {
        #expect(DragOutPolicy.dragImageOffset(index: 0) == CGPoint(x: 0, y: 0))
    }

    @Test func eachFurtherImageStepsRightAndDown() {
        #expect(DragOutPolicy.dragImageOffset(index: 1) == CGPoint(x: 4, y: -4))
        #expect(DragOutPolicy.dragImageOffset(index: 2) == CGPoint(x: 8, y: -8))
        #expect(DragOutPolicy.dragImageOffset(index: 5) == CGPoint(x: 20, y: -20))
    }
}
