import AppKit
import Foundation
import QuickLookThumbnailing
import os

/// A thumbnail for one stashed file.
///
/// `hasPreview` is false when QuickLook had nothing to offer and the system file
/// icon stands in — the card draws that differently (an icon wants padding, a
/// preview wants the full tile).
///
/// `@unchecked Sendable` justification: immutable after creation, and the image is
/// only ever read on the main actor.
public struct Thumbnail: @unchecked Sendable {
    public let image: NSImage
    public let hasPreview: Bool

    public init(image: NSImage, hasPreview: Bool) {
        self.image = image
        self.hasPreview = hasPreview
    }
}

/// QuickLook thumbnails for the stash, generated once per file and kept in memory.
///
/// The stack draws the same three files over and over — on every hover, every
/// re-layout, every settle — so the answer is cached by path and size, and callers
/// that ask for a file already in flight wait for that one generation instead of
/// starting a second.
public actor ThumbnailProvider {
    /// The QuickLook call, injectable so tests neither depend on the out-of-process
    /// generator nor on what it thinks of their fixture files.
    public typealias Generator = @Sendable (QLThumbnailGenerator.Request) async throws -> CGImage?

    private let size: CGFloat
    private let scale: CGFloat
    private let generator: Generator
    private let logger = Logger(subsystem: "app.notch", category: "dropzones.thumbnails")

    private var cache: [String: Thumbnail] = [:]
    private var inFlight: [String: Task<Thumbnail, Never>] = [:]

    /// - Parameters:
    ///   - size: the side of the square the card wants, in points.
    ///   - scale: backing scale of the screen the island is on. The default reads
    ///     `NSScreen.main` at the *call site* (default arguments are evaluated
    ///     there), which is where the main actor is.
    ///   - generator: defaults to `QLThumbnailGenerator.shared`.
    public init(
        size: CGFloat,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2,
        generator: @escaping Generator = ThumbnailProvider.quickLook
    ) {
        self.size = size
        self.scale = scale
        self.generator = generator
    }

    /// The thumbnail for `url`, or the system icon when QuickLook cannot render one.
    /// Never fails: a missing preview is a chrome difference, not an error path.
    public func thumbnail(for url: URL) async -> Thumbnail {
        let key = "\(url.path)|\(size)"
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let task = Task<Thumbnail, Never> { [generator, scale, size, logger] in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                // Seam asks for twice the drawn size on top of the scale, so a
                // thumbnail still looks sharp when a card grows on hover.
                size: CGSize(width: size * 2, height: size * 2),
                scale: scale,
                representationTypes: .thumbnail
            )
            do {
                guard let image = try await generator(request) else {
                    logger.debug("no QuickLook thumbnail for \(url.lastPathComponent, privacy: .public)")
                    return Self.fallback(for: url)
                }
                // Pixels back to points, keeping QuickLook's aspect ratio: the
                // requested size is a bounding box, not a promise of a square.
                let pixels = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                return Thumbnail(image: NSImage(cgImage: image, size: pixels), hasPreview: true)
            } catch {
                logger.debug("""
                    QuickLook failed for \(url.lastPathComponent, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                return Self.fallback(for: url)
            }
        }

        inFlight[key] = task
        let thumbnail = await task.value
        inFlight[key] = nil
        cache[key] = thumbnail
        return thumbnail
    }

    /// Forgets everything. Called when the stash is cleared so bitmaps for files
    /// that no longer exist are not held for the life of the app.
    public func clearCache() {
        cache.removeAll()
    }

    // MARK: - The two image sources

    /// `NSWorkspace.icon(forFile:)` is synchronous and never fails; creating it off
    /// the main actor is fine, the image is only read on it.
    private static func fallback(for url: URL) -> Thumbnail {
        Thumbnail(image: NSWorkspace.shared.icon(forFile: url.path), hasPreview: false)
    }

    /// The production generator. `generateBestRepresentation` calls back once, on a
    /// background queue, with the best representation it has.
    public static let quickLook: Generator = { request in
        try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    // `QLThumbnailRepresentation` is not Sendable; the `CGImage`
                    // inside it is all we need and does cross.
                    continuation.resume(returning: representation?.cgImage)
                }
            }
        }
    }
}
