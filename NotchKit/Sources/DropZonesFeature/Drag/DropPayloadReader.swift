import AppKit
import os

/// Turns a drop into files on disk.
///
/// Three payloads, in the order the design fixes (§2 "Reading the drop"), because
/// they are increasingly expensive and increasingly lossy:
///
/// 1. **Plain file URLs.** The common case (Finder, most apps) and free: the
///    files already exist where the user keeps them, and the stash copies them
///    itself afterwards.
/// 2. **File promises.** Mail attachments, Photos exports, anything the source
///    has not written to disk yet. The source writes them into our staging
///    folder on its own schedule, so this path waits — bounded by `timeout`.
/// 3. **Raw image data.** A picture dragged out of a web page or Preview is not
///    a file anywhere; it becomes `Image.png` in the staging folder.
///
/// Nothing at all → `[]`, and the drop is ignored.
///
/// `NSDraggingInfo` is not `Sendable` and its pasteboard must not be touched
/// after the drag ends, so every read happens on the main actor *before* the
/// first `await`; only the staging work crosses a suspension point.
public enum DropPayloadReader {

    private static let logger = Logger(subsystem: "app.notch", category: "dropzones.payload")

    /// The files this drop yielded, staging whatever was not already a file.
    ///
    /// - Parameters:
    ///   - info: the drop, read synchronously before any suspension.
    ///   - stagingRoot: normally `<tmp>/app.notch/DragStaging`; each drop gets its
    ///     own `<UUID>` folder underneath, so two drags of the same image never
    ///     collide.
    ///   - timeout: how long to wait for promised files. Whatever has arrived when
    ///     it elapses is used (design §4).
    @MainActor
    public static func fileURLs(
        from info: any NSDraggingInfo,
        stagingRoot: URL,
        timeout: TimeInterval = 5
    ) async -> [URL] {
        let pasteboard = info.draggingPasteboard

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !urls.isEmpty { return urls }

        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
        if !receivers.isEmpty {
            return await receive(receivers, into: stagingRoot, timeout: timeout)
        }

        // Read the data now, on the main actor: the pasteboard is the drag's, and
        // it is gone by the time a background write would ask for it.
        if let image = imageData(from: pasteboard) {
            return stage(pngData: image, in: stagingRoot)
        }

        logger.info("drop carried nothing we can use")
        return []
    }

    // MARK: - Promises

    /// Receives every promise into its own staging folder, giving up after
    /// `timeout`.
    ///
    /// The receivers report on a background queue, once per promised file, and a
    /// source that never answers must not wedge the drop — hence the race. The
    /// collector resumes the continuation exactly once, whichever side wins.
    @MainActor
    private static func receive(
        _ receivers: [NSFilePromiseReceiver],
        into stagingRoot: URL,
        timeout: TimeInterval
    ) async -> [URL] {
        let collector = PromiseCollector(expected: receivers.count)
        let queue = OperationQueue()
        queue.name = "app.notch.dropzones.promises"
        queue.qualityOfService = .userInitiated

        for receiver in receivers {
            guard let destination = makeStagingFolder(in: stagingRoot) else {
                collector.received(nil, error: nil)
                continue
            }
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: queue
            ) { url, error in
                collector.received(url, error: error)
            }
        }

        // Starts only once every receiver is under way, so a slow source gets the
        // full window rather than sharing it with the ones before it.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(timeout))
            collector.finish(timedOut: true)
        }
        let urls = await withCheckedContinuation { continuation in
            collector.attach(continuation)
        }
        deadline.cancel()
        return urls
    }

    /// Gathers promised file URLs from the receivers' background queue and hands
    /// them over exactly once.
    ///
    /// `@unchecked Sendable` justification: every stored property is read and
    /// written only inside `lock`.
    private final class PromiseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let expected: Int
        private var urls: [URL] = []
        private var settled = 0
        private var continuation: CheckedContinuation<[URL], Never>?
        private var isFinished = false

        init(expected: Int) {
            self.expected = expected
        }

        /// One promised file arrived (or failed). The count is compared against
        /// the number of *receivers*: a receiver standing for several files
        /// reports more than once, and those extra URLs are still collected — they
        /// simply do not extend the wait, which the timeout bounds anyway.
        func received(_ url: URL?, error: (any Error)?) {
            lock.lock()
            if let url { urls.append(url) }
            settled += 1
            let done = settled >= expected
            lock.unlock()
            if let error {
                DropPayloadReader.logger.error("promised file failed: \(error.localizedDescription, privacy: .public)")
            }
            if done { finish(timedOut: false) }
        }

        /// Resumes the waiter with whatever has arrived. Idempotent — the race
        /// between the last receiver and the deadline is decided here.
        func finish(timedOut: Bool) {
            lock.lock()
            guard !isFinished else { return lock.unlock() }
            isFinished = true
            let pending = continuation
            continuation = nil
            let collected = urls
            let missing = expected - settled
            lock.unlock()

            if timedOut {
                DropPayloadReader.logger.error("promise wait timed out with \(missing, privacy: .public) receiver(s) still pending")
            }
            pending?.resume(returning: collected)
        }

        /// Hands the collector the waiter. A promise that finished before the
        /// `await` started is resumed here instead.
        func attach(_ continuation: CheckedContinuation<[URL], Never>) {
            lock.lock()
            if isFinished {
                let collected = urls
                lock.unlock()
                continuation.resume(returning: collected)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    // MARK: - Image data

    /// PNG first: taking it avoids a decode/encode round trip and keeps whatever
    /// alpha the source had. TIFF is converted, because the stash stores files
    /// the user may open anywhere and `Image.tiff` is not that.
    @MainActor
    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        guard let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            logger.error("dragged TIFF data could not be converted to PNG")
            return nil
        }
        return png
    }

    private static func stage(pngData: Data, in stagingRoot: URL) -> [URL] {
        guard let folder = makeStagingFolder(in: stagingRoot) else { return [] }
        let url = folder.appendingPathComponent("Image.png")
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            logger.error("could not stage dragged image: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return [url]
    }

    // MARK: - Staging

    /// `<stagingRoot>/<UUID>/`, created. `nil` when the file system refuses,
    /// which turns into an ignored drop rather than a crash.
    private static func makeStagingFolder(in stagingRoot: URL) -> URL? {
        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logger.error("could not create staging folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return folder
    }
}
