import DropZonesShared
import Foundation
import os

/// The stash on disk: copies of the dropped files plus the index that describes them.
///
/// Layout under `baseDirectory` (in production `~/Library/Application Support/Notch`):
///
/// ```
/// Stash/<UUID>/<file name>   one folder per file, so two files called
///                            "Screenshot.png" never fight over a name
/// stash.json                 a `StashIndex`, written atomically
/// ```
///
/// An actor because the drop path, the drag-out promise delegate and the TTL timer
/// all reach for the same two paths from different tasks. The rules for *what* a
/// drop does to the index live in `StashIndex.apply`; this type only does the file
/// system work around them.
///
/// Originals are never moved or deleted: every file is copied, and `originalPath`
/// is kept only so "Reveal in Finder" can prefer the place the user knows.
public actor StashStore {
    private let baseDirectory: URL
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.notch", category: "dropzones.store")

    private var fileManager: FileManager { .default }

    public init(baseDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseDirectory = baseDirectory
        self.now = now
    }

    /// Where the copies live. `nonisolated` because it is derived from an immutable
    /// path and the "Reveal stash in Finder" menu row needs it synchronously.
    public nonisolated var stashDirectory: URL {
        baseDirectory.appendingPathComponent("Stash", isDirectory: true)
    }

    private nonisolated var indexURL: URL {
        baseDirectory.appendingPathComponent("stash.json")
    }

    // MARK: - Reading

    /// The current stash, after expiry and missing files have been dealt with.
    ///
    /// Three things can have happened since the index was written: the TTL ran out
    /// (everything goes), a stored file was deleted behind our back (that entry
    /// goes), or the file is unreadable (treated as an empty stash — the next drop
    /// rewrites it). Any pruning is persisted so the next load has nothing to do.
    public func load() -> StashIndex {
        var index = decodeIndex()

        if index.isExpired(now: now()) {
            clear()
            return StashIndex()
        }

        let missing = index.files.filter { !fileManager.fileExists(atPath: $0.storedPath) }
        guard !missing.isEmpty else { return index }

        logger.info("pruning \(missing.count, privacy: .public) stashed file(s) that are no longer on disk")
        index.files.removeAll { file in missing.contains { $0.id == file.id } }
        // A folder can outlive its file (the file deleted, the folder left behind);
        // removing it keeps `Stash/` from filling up with empty UUIDs.
        deleteFolders(of: missing)
        if index.files.isEmpty { index.removeAll() }
        writeIndex(index)
        return index
    }

    // MARK: - Writing

    /// Copies `urls` into the stash and applies `action` to the index.
    ///
    /// Files that cannot be copied are skipped and logged; if none of them copied
    /// the stash is left exactly as it was — including `stashedAt`, so a failed
    /// drop never restarts the 24-hour clock.
    @discardableResult
    public func stash(_ urls: [URL], action: StashDropAction) -> StashIndex {
        var index = load()
        let added = urls.compactMap(copyIntoStash)

        guard !added.isEmpty else {
            logger.error("stash drop of \(urls.count, privacy: .public) file(s) copied nothing; stash unchanged")
            return index
        }

        let replaced = index.files
        index.apply(action, adding: added, now: now())
        // Index first, files second: a crash in between leaves entries whose folder
        // is gone, which `load` prunes — the opposite order would lose files that
        // the index still promises.
        writeIndex(index)
        if action == .replace { deleteFolders(of: replaced) }
        return index
    }

    /// Empties the stash: both the copies and the index.
    public func clear() {
        remove(stashDirectory)
        remove(indexURL)
    }

    /// Copies a stashed file to `destination`, replacing whatever is there.
    ///
    /// Used by the drag-out file-promise delegate, which reports the thrown error
    /// to the receiving app; the stash itself is left untouched either way.
    public func write(file: StashedFile, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: URL(fileURLWithPath: file.storedPath), to: destination)
    }

    // MARK: - Copying

    /// Copies one dropped file into `Stash/<UUID>/<name>`. `nil` when it could not
    /// be copied — a file that vanished mid-drag, an unreadable volume, no space.
    private func copyIntoStash(_ url: URL) -> StashedFile? {
        let id = UUID()
        let folder = stashDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let name = url.lastPathComponent
        let destination = folder.appendingPathComponent(name)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            logger.error("""
                could not stash \(name, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            // Do not leave the empty UUID folder behind.
            remove(folder)
            return nil
        }

        return StashedFile(
            id: id,
            name: name,
            storedPath: destination.path,
            bytes: byteCount(of: destination),
            originalPath: url.path
        )
    }

    private func byteCount(of url: URL) -> Int64 {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return Int64(size)
        }
        // Directories have no `fileSizeKey`; the caption is allowed to say 0 rather
        // than walking a dropped folder on the drop path.
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
    }

    private func deleteFolders(of files: [StashedFile]) {
        for file in files {
            let folder = URL(fileURLWithPath: file.storedPath).deletingLastPathComponent()
            // Only ever inside our own Stash/, never the original.
            guard folder.deletingLastPathComponent().standardizedFileURL
                == stashDirectory.standardizedFileURL else { continue }
            remove(folder)
        }
    }

    private func remove(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("""
                could not remove \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: - The index file

    private func decodeIndex() -> StashIndex {
        guard fileManager.fileExists(atPath: indexURL.path) else { return StashIndex() }
        do {
            return try JSONDecoder().decode(StashIndex.self, from: Data(contentsOf: indexURL))
        } catch {
            logger.error("stash.json unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return StashIndex()
        }
    }

    private func writeIndex(_ index: StashIndex) {
        let encoder = JSONEncoder()
        // Pretty and sorted: the file is meant to be openable in an editor, and a
        // stable key order keeps diffs honest.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            logger.error("could not write stash.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
