import Foundation
import Testing
@testable import DropZonesShared

private let now = Date(timeIntervalSince1970: 1_757_000_000)

private func file(_ name: String, bytes: Int64 = 1_000) -> StashedFile {
    StashedFile(
        id: UUID(),
        name: name,
        storedPath: "/tmp/stash/\(name)",
        bytes: bytes,
        originalPath: "/Users/someone/Desktop/\(name)"
    )
}

@Suite struct StashIndexTests {

    // MARK: - apply(.replace)

    @Test func replaceSwapsTheFilesAndRestartsTheClock() {
        var index = StashIndex(files: [file("old.pdf")], stashedAt: now.addingTimeInterval(-3_600))
        let fresh = [file("a.png"), file("b.png")]

        index.apply(.replace, adding: fresh, now: now)

        #expect(index.files == fresh)
        #expect(index.stashedAt == now)
    }

    @Test func replaceOnAnEmptyStashSetsTheTimestamp() {
        var index = StashIndex()
        index.apply(.replace, adding: [file("a.png")], now: now)
        #expect(index.files.count == 1)
        #expect(index.stashedAt == now)
    }

    // MARK: - apply(.add)

    @Test func addAppendsAndKeepsTheExistingTimestamp() {
        // The TTL is measured from the *first* drop: adding must not buy the pile
        // another 24 hours, or a stash topped up hourly would never expire.
        let earlier = now.addingTimeInterval(-3_600)
        var index = StashIndex(files: [file("old.pdf")], stashedAt: earlier)

        index.apply(.add, adding: [file("new.png")], now: now)

        #expect(index.files.map(\.name) == ["old.pdf", "new.png"])
        #expect(index.stashedAt == earlier)
    }

    @Test func addOnAnEmptyStashStartsTheClock() {
        var index = StashIndex()
        index.apply(.add, adding: [file("a.png")], now: now)
        #expect(index.files.map(\.name) == ["a.png"])
        #expect(index.stashedAt == now)
    }

    // MARK: - Expiry

    @Test func aStashWithNoTimestampNeverExpires() {
        #expect(StashIndex().isExpired(now: now) == false)
    }

    @Test func expiresExactlyAtTheTTLBoundary() {
        let index = StashIndex(files: [file("a.png")], stashedAt: now)
        #expect(index.isExpired(now: now.addingTimeInterval(StashIndex.ttl - 1)) == false)
        #expect(index.isExpired(now: now.addingTimeInterval(StashIndex.ttl)) == true)
        #expect(index.isExpired(now: now.addingTimeInterval(StashIndex.ttl + 1)) == true)
    }

    @Test func ttlIsTwentyFourHours() {
        #expect(StashIndex.ttl == 86_400)
    }

    // MARK: - Totals and clearing

    @Test func totalBytesSumsEveryFile() {
        let index = StashIndex(files: [file("a", bytes: 100), file("b", bytes: 89_000)], stashedAt: now)
        #expect(index.totalBytes == 89_100)
    }

    @Test func totalBytesOfAnEmptyStashIsZero() {
        #expect(StashIndex().totalBytes == 0)
    }

    @Test func removeAllClearsFilesAndTheTimestamp() {
        // Leaving `stashedAt` behind would arm a TTL timer for a stash with nothing in it.
        var index = StashIndex(files: [file("a.png")], stashedAt: now)
        index.removeAll()
        #expect(index.files.isEmpty)
        #expect(index.stashedAt == nil)
    }

    // MARK: - Persistence

    @Test func roundTripsThroughJSON() throws {
        let index = StashIndex(files: [file("a.png", bytes: 42)], stashedAt: now)
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(StashIndex.self, from: data)
        #expect(decoded == index)
    }

    @Test func aFileWithoutAnOriginalPathRoundTrips() throws {
        // Promise drops and raw image drops have no original on disk.
        let staged = StashedFile(
            id: UUID(),
            name: "Image.png",
            storedPath: "/tmp/stash/Image.png",
            bytes: 7,
            originalPath: nil
        )
        let data = try JSONEncoder().encode(StashIndex(files: [staged], stashedAt: now))
        let decoded = try JSONDecoder().decode(StashIndex.self, from: data)
        #expect(decoded.files.first?.originalPath == nil)
    }
}
