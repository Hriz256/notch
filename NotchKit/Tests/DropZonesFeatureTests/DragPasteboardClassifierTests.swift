import AppKit
import Testing
@testable import DropZonesFeature

/// The cheap "is this drag carrying files?" test the drag monitor runs on every
/// dragged event until it succeeds. It sees only the pasteboard's type list, so
/// these tests are the whole contract.
@Suite struct DragPasteboardClassifierTests {

    @Test func anEmptyPasteboardIsNotFileContent() {
        // The very first dragged event of a session routinely arrives before the
        // source has filled the pasteboard — that must read as "not yet", not as
        // "never", which is why the detector keeps asking.
        #expect(!DragPasteboardClassifier.hasFileContent(types: []))
    }

    @Test func fileURLsAreFileContent() {
        #expect(DragPasteboardClassifier.hasFileContent(types: [.fileURL]))
    }

    @Test func everyFilePromiseTypeIsFileContent() {
        // Mail attachments and Photos exports put *only* promise types on the
        // pasteboard; the catcher registers the same list, so the two halves must
        // agree or we would open the zones for a drag we then refuse.
        let promises = NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:))
        #expect(!promises.isEmpty)
        for type in promises {
            #expect(DragPasteboardClassifier.hasFileContent(types: [type]), "\(type.rawValue)")
        }
    }

    @Test func imageDataIsFileContent() {
        // A dragged image (a screenshot out of Preview, a picture off a web page)
        // has no file URL at all; `DropPayloadReader` writes it out as Image.png.
        #expect(DragPasteboardClassifier.hasFileContent(types: [.png]))
        #expect(DragPasteboardClassifier.hasFileContent(types: [.tiff]))
    }

    @Test func chromesPrivateTypeIsFileContent() {
        // Chrome advertises nothing but this at drag start; without the special
        // case every Chrome drag would look like an empty pasteboard.
        let chrome = NSPasteboard.PasteboardType("org.chromium.chromium-initiated-drag")
        #expect(DragPasteboardClassifier.hasFileContent(types: [chrome]))
    }

    @Test func textAndWebURLsAreNotFileContent() {
        // Dragging a selection or a link must leave the island alone.
        #expect(!DragPasteboardClassifier.hasFileContent(types: [.string]))
        #expect(!DragPasteboardClassifier.hasFileContent(types: [.URL]))
        #expect(!DragPasteboardClassifier.hasFileContent(types: [.string, .html, .rtf]))
    }

    @Test func oneFileTypeAmongManyIsEnough() {
        #expect(DragPasteboardClassifier.hasFileContent(types: [.string, .URL, .fileURL]))
    }
}
