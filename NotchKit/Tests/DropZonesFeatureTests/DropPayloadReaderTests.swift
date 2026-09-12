import AppKit
import Testing
@testable import DropZonesFeature

/// What a drop actually yields. Two of the three paths are testable headlessly —
/// plain file URLs and raw image data. The `NSFilePromiseReceiver` path cannot be:
/// a receiver only exists inside a live drag session started by another
/// application, so it is verified by inspection here and by the user's real drags
/// from Mail/Photos (see the task report).
@MainActor @Suite struct DropPayloadReaderTests {

    private func makeStagingRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DropPayloadReaderTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFile(_ name: String, contents: String = "hello") throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DropPayloadReaderTests-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func pngData(width: Int = 8, height: Int = 4) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.systemPink.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - File URLs

    @Test func fileURLsComeStraightOffThePasteboard() async throws {
        let staging = makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        let info = FakeDraggingInfo()
        info.pasteboard.writeObjects([a as NSURL, b as NSURL])

        let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: staging)

        #expect(urls.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(urls.map(\.standardizedFileURL) == [a, b].map(\.standardizedFileURL))
        #expect(
            !FileManager.default.fileExists(atPath: staging.path),
            "a plain file drag stages nothing — the originals are read where they are"
        )
    }

    @Test func aWebURLIsNotAFile() async throws {
        // Dragging a link out of Safari puts an http URL on the pasteboard;
        // `.urlReadingFileURLsOnly` filters it out and there is nothing else to
        // fall back to, so the drop is ignored.
        let staging = makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let info = FakeDraggingInfo()
        info.pasteboard.writeObjects([URL(string: "https://example.com")! as NSURL])

        let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: staging)

        #expect(urls.isEmpty)
    }

    // MARK: - Image data

    @Test func rawPNGDataIsWrittenIntoTheStagingFolder() async throws {
        let staging = makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let data = try pngData()
        let info = FakeDraggingInfo()
        info.pasteboard.setData(data, forType: .png)

        let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: staging)

        let url = try #require(urls.first)
        #expect(urls.count == 1)
        #expect(url.lastPathComponent == "Image.png")
        // <stagingRoot>/<UUID>/Image.png — one folder per drop, so two dragged
        // images never fight over the name.
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == staging.standardizedFileURL)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func tiffDataIsConvertedToPNG() async throws {
        let staging = makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let image = NSImage(size: NSSize(width: 8, height: 4), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let info = FakeDraggingInfo()
        info.pasteboard.setData(tiff, forType: .tiff)

        let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: staging)

        let url = try #require(urls.first)
        #expect(url.lastPathComponent == "Image.png")
        let written = try Data(contentsOf: url)
        let rep = try #require(NSBitmapImageRep(data: written))
        #expect(rep.pixelsWide == 8)
        #expect(rep.pixelsHigh == 4)
        // Really a PNG, not a TIFF under a .png name.
        #expect(written.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func pngIsPreferredOverTiffWhenBothAreOffered() async throws {
        // Most sources advertise both; taking the PNG skips a decode/encode round
        // trip and keeps any alpha the source had.
        let staging = makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let png = try pngData()
        let info = FakeDraggingInfo()
        info.pasteboard.setData(png, forType: .png)
        let other = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        info.pasteboard.setData(other.tiffRepresentation, forType: .tiff)

        let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: staging)

        #expect(try Data(contentsOf: try #require(urls.first)) == png)
    }

    // MARK: - Nothing at all

    @Test func anEmptyPasteboardYieldsNothingAndCreatesNothing() async throws {
        let staging = makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let info = FakeDraggingInfo()

        let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: staging)

        #expect(urls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func textOnlyDragsYieldNothing() async throws {
        let staging = makeStagingRoot()
        defer { try? FileManager.default.removeItem(at: staging) }
        let info = FakeDraggingInfo()
        info.pasteboard.setString("just some text", forType: .string)

        let urls = await DropPayloadReader.fileURLs(from: info, stagingRoot: staging)

        #expect(urls.isEmpty)
    }
}
