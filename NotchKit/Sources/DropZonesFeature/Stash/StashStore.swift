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
    /// How long a `Stash/<UUID>` folder with no index entry is left alone before ``load()``
    /// sweeps it: one hour.
    ///
    /// A drag-out that the receiver took by *file URL* rather than by redeeming the promise
    /// leaves exactly that — an entry detached from a folder still on disk (see
    /// ``detach(fileIDs:)``) — and the receiver may read those bytes long after the drop: a
    /// browser file input reads on submit, an uploader after the drag. An hour is far more
    /// than any of that, and short enough that `Stash/` does not grow for ever.
    public static let orphanLifetime: TimeInterval = 3_600

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
    /// goes), or `stash.json` could not be turned into a `StashIndex` (treated as an
    /// empty stash and rewritten on the spot, so a corrupt file is not re-read and
    /// re-logged forever). Any pruning is persisted so the next load has nothing to do.
    ///
    /// A file that could not be *read* is the one case where nothing is written: see
    /// ``readIndex()``.
    ///
    /// It is also where folders nothing in the index points at are swept, once they are
    /// ``orphanLifetime`` old — the bytes a URL drag-out detached, and anything a failed
    /// write or a repaired index left behind.
    public func load() -> StashIndex {
        var index: StashIndex
        switch readIndex() {
        case let .index(decoded):
            index = decoded
        case .corrupt:
            let empty = StashIndex()
            writeIndex(empty)
            sweepOrphanFolders(keeping: empty)
            return empty
        case .unreadable:
            // Not swept either: with no index to compare against, every folder in the
            // stash would look like an orphan.
            return StashIndex()
        }

        if index.isExpired(now: now()) {
            clear()
            return StashIndex()
        }

        let missing = index.files.filter { !fileManager.fileExists(atPath: $0.storedPath) }
        if !missing.isEmpty {
            logger.info("pruning \(missing.count, privacy: .public) stashed file(s) that are no longer on disk")
            index.files.removeAll { file in missing.contains { $0.id == file.id } }
            // A folder can outlive its file (the file deleted, the folder left behind);
            // removing it keeps `Stash/` from filling up with empty UUIDs.
            deleteFolders(of: missing)
            if index.files.isEmpty { index.removeAll() }
            writeIndex(index)
        }
        sweepOrphanFolders(keeping: index)
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

    /// Takes files out of the index and leaves their bytes on disk.
    ///
    /// The drag-out path for a receiver that took the *file URL* instead of redeeming the
    /// promise (see ``orphanLifetime``): the files have left the shelf as surely as
    /// redeemed ones — the user watched them go — but the receiver may not have read them
    /// yet, and ``remove(fileID:)`` would pull the bytes out from under it. The folders
    /// nothing points at any more are swept by a later ``load()``.
    ///
    /// Ids that are not in the stash are ignored, exactly as in ``remove(fileID:)``.
    @discardableResult
    public func detach(fileIDs: Set<UUID>) -> StashIndex {
        var index = load()
        guard index.files.contains(where: { fileIDs.contains($0.id) }) else { return index }

        index.files.removeAll { fileIDs.contains($0.id) }
        // Emptying the index outright, like `remove`, so no TTL timer is armed for a stash
        // with nothing left in it.
        if index.files.isEmpty { index.removeAll() }
        writeIndex(index)
        return index
    }

    /// Empties the stash: both the copies and the index.
    ///
    /// Everything under `Stash/` goes, detached folders included: "Clear stash" and the
    /// TTL mean the bytes are gone now, not in an hour.
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
    /// The temporary name carries no part of the destination's: a file name may be up to
    /// 255 *bytes*, and `.<name>.notch-<UUID>` added 44 of them — so dragging out anything
    /// with a long name (a saved web page, a photo library export) failed with
    /// `ENAMETOOLONG` before a byte was copied. The UUID alone is unique enough.
    ///
    /// Used by the drag-out file-promise delegate, which reports the thrown error
    /// to the receiving app; the stash itself is left untouched either way.
    public func write(file: StashedFile, to destination: URL) throws {
        let source = URL(fileURLWithPath: file.storedPath)
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".notch-\(UUID().uuidString)")

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

    /// Deletes every folder in `Stash/` that `index` does not point at and that has not
    /// been touched for ``orphanLifetime``.
    ///
    /// The age is the whole point: a folder detached a moment ago is very probably being
    /// read by the application the user just dropped it on, whereas one an hour old is
    /// nobody's — a drag-out long finished, a failed index write, or the repair of a
    /// corrupt index.
    private func sweepOrphanFolders(keeping index: StashIndex) {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: stashDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let kept = Set(index.files.map {
            URL(fileURLWithPath: $0.storedPath).deletingLastPathComponent().standardizedFileURL
        })
        var swept = 0
        for folder in folders where !kept.contains(folder.standardizedFileURL) {
            guard let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
                now().timeIntervalSince(modified) >= Self.orphanLifetime else { continue }
            remove(folder)
            swept += 1
        }
        if swept > 0 {
            logger.info("swept \(swept, privacy: .public) stash folder(s) nothing points at any more")
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

    /// What `stash.json` yielded.
    private enum IndexRead {
        /// The index on disk — or an empty one, on a machine that has never stashed
        /// anything. Nothing to repair.
        case index(StashIndex)
        /// The bytes are there and are not a `StashIndex`. Rewriting an empty index over
        /// them is the repair: a file we cannot decode we will never decode, and left
        /// alone it is re-read and re-logged on every load for ever.
        case corrupt
        /// The bytes could not be read at all — permissions, a volume that went away, an
        /// I/O error. **Nothing is written.** The index is very probably still perfectly
        /// good, and rewriting an empty one over it would turn a transient failure into
        /// the permanent loss of every file in the stash.
        case unreadable
    }

    private func readIndex() -> IndexRead {
        guard fileManager.fileExists(atPath: indexURL.path) else { return .index(StashIndex()) }

        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            logger.error("""
                stash.json could not be read, leaving it alone: \
                \(error.localizedDescription, privacy: .public)
                """)
            return .unreadable
        }

        do {
            return .index(try JSONDecoder().decode(StashIndex.self, from: data))
        } catch {
            logger.error("stash.json unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return .corrupt
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
