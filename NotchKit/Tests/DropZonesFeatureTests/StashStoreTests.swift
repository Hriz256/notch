import DropZonesShared
import Foundation
import Testing
@testable import DropZonesFeature

/// A throw-away `~/Library/Application Support/Notch` plus a folder of source
/// files to drop. Never touches the real app-support directory.
private struct Fixture {
    let base: URL
    let sources: URL

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StashStoreTests-\(UUID().uuidString)")
        base = root.appendingPathComponent("Notch")
        sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    /// Writes `contents` into `sources/<subdirectory>/<name>` and returns its URL.
    @discardableResult
    func makeFile(_ name: String, contents: String = "hello", in subdirectory: String? = nil) throws -> URL {
        var directory = sources
        if let subdirectory {
            directory = directory.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    var stashDirectory: URL { base.appendingPathComponent("Stash", isDirectory: true) }
    var indexURL: URL { base.appendingPathComponent("stash.json") }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base.deletingLastPathComponent())
    }
}

private let start = Date(timeIntervalSince1970: 1_757_000_000)

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

@Suite struct StashStoreTests {

    // MARK: - stash

    @Test func stashingTwoFilesCopiesBothAndStartsTheClock() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt", contents: "alpha")
        let b = try fixture.makeFile("b.txt", contents: "beta")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([a, b], action: .replace)

        #expect(index.files.count == 2)
        #expect(index.stashedAt == start)
        #expect(index.files.map(\.name) == ["a.txt", "b.txt"])
        // The copies live under Stash/<UUID>/<name> and carry the real byte count.
        for file in index.files {
            #expect(exists(file.storedPath))
            #expect(URL(fileURLWithPath: file.storedPath).deletingLastPathComponent()
                .deletingLastPathComponent().standardizedFileURL == fixture.stashDirectory.standardizedFileURL)
        }
        #expect(index.files.map(\.bytes) == [5, 4], "sizes come from the copies, not a guess")
        let copied = try String(contentsOf: URL(fileURLWithPath: index.files[0].storedPath), encoding: .utf8)
        #expect(copied == "alpha")
        // Originals are never moved.
        #expect(exists(a))
        #expect(exists(b))
        #expect(index.files[0].originalPath == a.path)
        // And the index is on disk, decodable as exactly a StashIndex.
        let onDisk = try JSONDecoder().decode(StashIndex.self, from: Data(contentsOf: fixture.indexURL))
        #expect(onDisk == index)
    }

    @Test func filesWithTheSameNameGetTheirOwnFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let one = try fixture.makeFile("report.txt", contents: "one", in: "one")
        let two = try fixture.makeFile("report.txt", contents: "twotwo", in: "two")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([one, two], action: .replace)

        #expect(index.files.count == 2)
        #expect(index.files[0].storedPath != index.files[1].storedPath)
        #expect(index.files.map(\.bytes) == [3, 6])
    }

    @Test func replaceDeletesThePreviouslyStoredFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let old = try fixture.makeFile("old.txt")
        let new = try fixture.makeFile("new.txt")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let first = await store.stash([old], action: .replace)
        let oldFolder = URL(fileURLWithPath: first.files[0].storedPath).deletingLastPathComponent()

        let second = await store.stash([new], action: .replace)

        #expect(second.files.map(\.name) == ["new.txt"])
        #expect(!exists(oldFolder))
        #expect(exists(second.files[0].storedPath))
    }

    @Test func addKeepsTheOldFilesAndTheOriginalTimestamp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")
        let b = try fixture.makeFile("b.txt")
        let c = try fixture.makeFile("c.txt")

        let later = start.addingTimeInterval(3_600)
        let clock = MutableClock(start)
        let store = StashStore(baseDirectory: fixture.base, now: clock.read)

        let first = await store.stash([a, b], action: .replace)
        clock.set(later)
        let second = await store.stash([c], action: .add)

        #expect(second.files.count == 3)
        #expect(second.stashedAt == start, "the TTL runs from the first drop")
        for file in first.files { #expect(exists(file.storedPath)) }
        #expect(exists(second.files[2].storedPath))
    }

    @Test func aDropWhoseCopiesAllFailLeavesTheStashUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")
        let missing = fixture.sources.appendingPathComponent("gone.txt")

        let clock = MutableClock(start)
        let store = StashStore(baseDirectory: fixture.base, now: clock.read)
        let first = await store.stash([a], action: .replace)

        clock.set(start.addingTimeInterval(60))
        let second = await store.stash([missing], action: .replace)

        #expect(second == first, "nothing copied, so stashedAt and the files stay as they were")
        #expect(exists(first.files[0].storedPath))
    }

    @Test func aPartlyFailedDropStashesTheFilesThatCopied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")
        let missing = fixture.sources.appendingPathComponent("gone.txt")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([missing, a], action: .replace)

        #expect(index.files.map(\.name) == ["a.txt"])
        // The skipped file leaves no empty folder behind.
        let folders = try FileManager.default.contentsOfDirectory(atPath: fixture.stashDirectory.path)
        #expect(folders.count == 1)
    }

    // MARK: - load

    @Test func loadReturnsWhatWasStashed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")

        let written = await StashStore(baseDirectory: fixture.base, now: { start })
            .stash([a], action: .replace)
        let reloaded = await StashStore(baseDirectory: fixture.base, now: { start }).load()

        #expect(reloaded == written)
    }

    @Test func loadPrunesEntriesWhoseStoredFileIsGone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")
        let b = try fixture.makeFile("b.txt")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([a, b], action: .replace)
        let orphanFolder = URL(fileURLWithPath: index.files[0].storedPath).deletingLastPathComponent()
        try FileManager.default.removeItem(atPath: index.files[0].storedPath)

        let loaded = await store.load()

        #expect(loaded.files.map(\.name) == ["b.txt"])
        #expect(loaded.stashedAt == start)
        #expect(!exists(orphanFolder), "the leftover folder goes with the entry")
        // The pruning is persisted, so the next load does not repeat it.
        let onDisk = try JSONDecoder().decode(StashIndex.self, from: Data(contentsOf: fixture.indexURL))
        #expect(onDisk == loaded)
    }

    @Test func loadAfterTheTTLClearsEverything() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")

        let clock = MutableClock(start)
        let store = StashStore(baseDirectory: fixture.base, now: clock.read)
        _ = await store.stash([a], action: .replace)

        clock.set(start.addingTimeInterval(25 * 3_600))
        let loaded = await store.load()

        #expect(loaded == StashIndex())
        #expect(!exists(fixture.stashDirectory))
        #expect(!exists(fixture.indexURL))
        #expect(exists(a), "the original is still the user's file")
    }

    @Test func loadTreatsAnUnreadableIndexAsEmptyAndRewritesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.base, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: fixture.indexURL)

        let loaded = await StashStore(baseDirectory: fixture.base, now: { start }).load()

        #expect(loaded == StashIndex())
        // The garbage is replaced, so the next load has nothing to complain about.
        let onDisk = try JSONDecoder().decode(StashIndex.self, from: Data(contentsOf: fixture.indexURL))
        #expect(onDisk == StashIndex())
    }

    @Test func loadOnAFreshMachineIsEmptyAndCreatesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let loaded = await StashStore(baseDirectory: fixture.base, now: { start }).load()

        #expect(loaded == StashIndex())
        #expect(!exists(fixture.indexURL))
    }

    // MARK: - clear

    @Test func clearRemovesTheFilesAndTheIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        _ = await store.stash([a], action: .replace)

        await store.clear()

        #expect(!exists(fixture.stashDirectory))
        #expect(!exists(fixture.indexURL))
        let reloaded = await store.load()
        #expect(reloaded == StashIndex())
        #expect(exists(a))
    }

    // MARK: - write(file:to:)

    @Test func writeCopiesTheStoredFileToTheDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt", contents: "alpha")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([a], action: .replace)
        let destination = fixture.sources.appendingPathComponent("out/a.txt")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try await store.write(file: index.files[0], to: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == "alpha")
        #expect(exists(index.files[0].storedPath), "the stash keeps its copy")
    }

    @Test func writeOverwritesAnExistingDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt", contents: "alpha")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([a], action: .replace)
        let destination = fixture.sources.appendingPathComponent("existing.txt")
        try Data("stale".utf8).write(to: destination)

        try await store.write(file: index.files[0], to: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written == "alpha")
    }

    @Test func writeThrowsWhenTheStoredFileIsGone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([a], action: .replace)
        try FileManager.default.removeItem(atPath: index.files[0].storedPath)

        // The promise delegate reports the failure to the receiving app.
        await #expect(throws: (any Error).self) {
            try await store.write(
                file: index.files[0],
                to: fixture.sources.appendingPathComponent("out.txt")
            )
        }
    }

    @Test func aFailedWriteLeavesAnExistingDestinationIntact() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let a = try fixture.makeFile("a.txt", contents: "alpha")

        let store = StashStore(baseDirectory: fixture.base, now: { start })
        let index = await store.stash([a], action: .replace)
        // The receiving app already has a file there, and our copy has vanished.
        let destination = fixture.sources.appendingPathComponent("precious.txt")
        try Data("the user's own bytes".utf8).write(to: destination)
        try FileManager.default.removeItem(atPath: index.files[0].storedPath)

        await #expect(throws: (any Error).self) {
            try await store.write(file: index.files[0], to: destination)
        }

        let survived = try String(contentsOf: destination, encoding: .utf8)
        #expect(survived == "the user's own bytes", "a failed write must not destroy the destination")
        // And no half-written temporary is left next to it.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.sources.path)
        #expect(siblings.filter { $0.contains(".notch-") }.isEmpty)
    }

    // MARK: - stashDirectory

    @Test func stashDirectoryIsTheStashFolderInsideTheBase() {
        let base = URL(fileURLWithPath: "/tmp/Notch")
        let store = StashStore(baseDirectory: base, now: { start })
        #expect(store.stashDirectory.standardizedFileURL
            == base.appendingPathComponent("Stash", isDirectory: true).standardizedFileURL)
    }
}

/// A clock the tests move by hand.
///
/// `@unchecked Sendable` justification: the only mutable state is guarded by `lock`.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func set(_ date: Date) { lock.withLock { self.date = date } }

    /// The synchronous `() -> Date` the store takes.
    var read: @Sendable () -> Date { { [self] in lock.withLock { date } } }
}
