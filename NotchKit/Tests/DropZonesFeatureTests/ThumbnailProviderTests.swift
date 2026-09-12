import AppKit
import Foundation
import QuickLookThumbnailing
import Testing
@testable import DropZonesFeature

/// What the provider asked QuickLook for, and how often.
///
/// `QLThumbnailGenerator.Request` is not `Sendable`, so the spy keeps the three
/// values the tests care about rather than the request object itself.
private struct RecordedRequest: Sendable, Equatable {
    var size: CGSize
    var scale: CGFloat
    var representationTypes: UInt

    init(_ request: QLThumbnailGenerator.Request) {
        size = request.size
        scale = request.scale
        representationTypes = request.representationTypes.rawValue
    }
}

private actor GeneratorSpy {
    private(set) var requests: [RecordedRequest] = []
    var count: Int { requests.count }

    func record(_ request: RecordedRequest) { requests.append(request) }
    func request(_ index: Int) -> RecordedRequest { requests[index] }
}

/// A 4×4 red bitmap — enough to prove the generator's image is what comes back.
private func makeImage(width: Int = 4, height: Int = 4) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private struct GeneratorFailure: Error {}

/// A real file on disk: QuickLook and `NSWorkspace` both want a path that exists.
private func temporaryFile(named name: String, contents: Data = Data("hello".utf8)) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ThumbnailProviderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url)
    return url
}

@Suite struct ThumbnailProviderTests {

    @Test func aGeneratedImageCountsAsAPreview() async throws {
        let url = try temporaryFile(named: "a.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spy = GeneratorSpy()

        let provider = ThumbnailProvider(size: 48, scale: 2) { request in
            await spy.record(RecordedRequest(request))
            return makeImage(width: 96, height: 64)
        }
        let thumbnail = await provider.thumbnail(for: url)

        #expect(thumbnail.hasPreview)
        #expect(thumbnail.image.size.width > 0)
        #expect(thumbnail.image.size.height > 0)
        // Pixels come back divided by the scale, and the aspect ratio is kept —
        // QuickLook's `size` is a bounding box, not a square.
        #expect(thumbnail.image.size == CGSize(width: 48, height: 32))
    }

    @Test func theRequestDoublesTheAskedSizeAndCarriesTheScale() async throws {
        let url = try temporaryFile(named: "a.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spy = GeneratorSpy()

        let provider = ThumbnailProvider(size: 22, scale: 3) { request in
            await spy.record(RecordedRequest(request))
            return makeImage()
        }
        _ = await provider.thumbnail(for: url)

        let request = await spy.request(0)
        #expect(request.size == CGSize(width: 44, height: 44))
        #expect(request.scale == 3)
        #expect(request.representationTypes == QLThumbnailGenerator.Request.RepresentationTypes.thumbnail.rawValue)
    }

    @Test func aFailingGeneratorFallsBackToTheSystemIcon() async throws {
        let url = try temporaryFile(named: "mystery.notarealtype")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let provider = ThumbnailProvider(size: 48, scale: 2) { _ in throw GeneratorFailure() }
        let thumbnail = await provider.thumbnail(for: url)

        #expect(!thumbnail.hasPreview)
        #expect(thumbnail.image.size.width > 0)
    }

    @Test func aGeneratorWithNothingToShowFallsBackToo() async throws {
        let url = try temporaryFile(named: "mystery.notarealtype")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let provider = ThumbnailProvider(size: 48, scale: 2) { _ in nil }
        let thumbnail = await provider.thumbnail(for: url)

        #expect(!thumbnail.hasPreview)
        #expect(thumbnail.image.size.width > 0)
    }

    @Test func theSecondCallForTheSameFileIsServedFromTheCache() async throws {
        let url = try temporaryFile(named: "a.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spy = GeneratorSpy()

        let provider = ThumbnailProvider(size: 48, scale: 2) { request in
            await spy.record(RecordedRequest(request))
            return makeImage()
        }
        let first = await provider.thumbnail(for: url)
        let second = await provider.thumbnail(for: url)

        #expect(await spy.count == 1)
        #expect(first.image === second.image)
    }

    @Test func aFallbackIsCachedAsWell() async throws {
        let url = try temporaryFile(named: "mystery.notarealtype")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spy = GeneratorSpy()

        let provider = ThumbnailProvider(size: 48, scale: 2) { request in
            await spy.record(RecordedRequest(request))
            throw GeneratorFailure()
        }
        _ = await provider.thumbnail(for: url)
        _ = await provider.thumbnail(for: url)

        #expect(await spy.count == 1, "a file QuickLook cannot preview is not retried on every redraw")
    }

    @Test func concurrentCallsForTheSameFileGenerateOnce() async throws {
        let url = try temporaryFile(named: "a.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spy = GeneratorSpy()

        let provider = ThumbnailProvider(size: 48, scale: 2) { request in
            await spy.record(RecordedRequest(request))
            try await Task.sleep(for: .milliseconds(20))
            return makeImage()
        }
        async let first = provider.thumbnail(for: url)
        async let second = provider.thumbnail(for: url)
        let both = await [first, second]

        #expect(await spy.count == 1, "the thumbnail stack asks for the same file from several views")
        #expect(both[0].image === both[1].image)
    }

    @Test func differentFilesGetTheirOwnThumbnails() async throws {
        let a = try temporaryFile(named: "a.txt")
        let b = try temporaryFile(named: "b.txt")
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let spy = GeneratorSpy()

        let provider = ThumbnailProvider(size: 48, scale: 2) { request in
            await spy.record(RecordedRequest(request))
            return makeImage()
        }
        _ = await provider.thumbnail(for: a)
        _ = await provider.thumbnail(for: b)

        #expect(await spy.count == 2)
    }

    /// The production path, exercised end to end on a real PNG: the out-of-process
    /// QuickLook generator does answer under `swift test`, so the default generator
    /// — not just the injected ones — is covered.
    @Test func theRealQuickLookPathAnswersForAPNG() async throws {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.systemBlue.drawSwatch(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        image.unlockFocus()
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
            .representation(using: .png, properties: [:]))
        let url = try temporaryFile(named: "swatch.png", contents: data)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let provider = ThumbnailProvider(size: 48, scale: 2)
        let thumbnail = await provider.thumbnail(for: url)

        #expect(thumbnail.image.size.width > 0)
        #expect(thumbnail.image.size.height > 0)
        #expect(thumbnail.hasPreview, "QuickLook previews a PNG")
    }
}
