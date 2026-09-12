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
    /// goes), or the file is unreadable (treated as an empty stash and rewritten on
    /// the spot, so a corrupt `stash.json` is not re-read and re-logged forever).
    /// Any pruning is persisted so the next load has nothing to do.
    public func load() -> StashIndex {
        guard var index = decodeIndex() else {
            let empty = StashIndex()
            writeIndex(empty)
            return empty
        }

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
        // the index still promises. And only once the new index is actually on disk:
        // if the write failed, the old index is still the truth and still points at
        // those folders.
        if writeIndex(index), action == .replace { deleteFolders(of: replaced) }
        return index
    }

    /// Takes one file out of the stash: its folder and its index entry.
    ///
    /// This is the drag-out-one-file path (and the "Remove <name>" menu row): the rest
    /// of the pile is left exactly as it was, `stashedAt` included, so taking a file out
    /// never restarts — or shortens — the 24-hour clock on the ones still there. Removing
    /// the last file empties the index outright, which is what stops a TTL timer being
    /// armed for a stash with nothing in it.
    ///
    /// An id that is not in the stash is not an error: the file has already gone (a
    /// second drag-out of the same tile, a menu row clicked twice), and the index the
    /// caller gets back is simply the current one.
    @discardableResult
    public func remove(fileID: UUID) -> StashIndex {
        var index = load()
        guard let file = index.files.first(where: { $0.id == fileID }) else { return index }

        index.files.removeAll { $0.id == fileID }
        if index.files.isEmpty { index.removeAll() }
        // Index first, folder second — the same order as `stash`, and for the same
        // reason: an entry whose folder is gone is pruned by `load`, whereas a folder
        // deleted under an index that still promises it loses the file for good.
        if writeIndex(index) { deleteFolders(of: [file]) }
        return index
    }

    /// Empties the stash: both the copies and the index.
    public func clear() {
        remove(stashDirectory)
        remove(indexURL)
    }

    /// Copies a stashed file to `destination`, replacing whatever is there.
    ///
    /// The copy lands on a hidden sibling name first and only then takes the
    /// destination's place, so a failure half way through — the stored file gone,
    /// a full disk — leaves an existing file at `destination` exactly as it was.
    /// Deleting first and copying second would destroy the receiver's file on a
    /// failed drag-out.
    ///
    /// Used by the drag-out file-promise delegate, which reports the thrown error
    /// to the receiving app; the stash itself is left untouched either way.
    public func write(file: StashedFile, to destination: URL) throws {
        let source = URL(fileURLWithPath: file.storedPath)
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).notch-\(UUID().uuidString)")

        do {
            try fileManager.copyItem(at: source, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            // `replaceItemAt` consumes the temporary on success; on any failure it
            // may still be there, and it is ours to clean up.
            remove(temporary)
            throw error
        }
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

    /// The index on disk, or `nil` when there is a file and it cannot be read —
    /// the one case the caller has to repair. A missing file is not a failure: a
    /// fresh machine simply has an empty stash and nothing to write.
    private func decodeIndex() -> StashIndex? {
        guard fileManager.fileExists(atPath: indexURL.path) else { return StashIndex() }
        do {
            return try JSONDecoder().decode(StashIndex.self, from: Data(contentsOf: indexURL))
        } catch {
            logger.error("stash.json unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes the index atomically. `false` when it did not land — the caller must
    /// not then delete files the index on disk still refers to.
    @discardableResult
    private func writeIndex(_ index: StashIndex) -> Bool {
        let encoder = JSONEncoder()
        // Pretty and sorted: the file is meant to be openable in an editor, and a
        // stable key order keeps diffs honest.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try encoder.encode(index).write(to: indexURL, options: .atomic)
            return true
        } catch {
            logger.error("could not write stash.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
