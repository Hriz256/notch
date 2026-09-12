import Foundation
import Testing
@testable import CodeAgentFeature

private struct Fixture {
    let root: URL
    let cacheURL: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeSparklineTests-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        cacheURL = base.appendingPathComponent("cache/claude-usage-cache.json")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("-Users-me-alpha"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("-Users-me-beta"),
            withIntermediateDirectories: true
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private func timestamp(_ date: Date) -> String {
    // `ISO8601DateFormatter` is not `Sendable`, so it cannot be a shared global here.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func line(id: String, request: String, tokens: Int, at date: Date) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp(date))",\
    "requestId":"\(request)","message":{"id":"\(id)","usage":\
    {"input_tokens":\(tokens),"output_tokens":0,"cache_creation_input_tokens":0,\
    "cache_read_input_tokens":0}}}
    """
}

@Suite struct ClaudeSparklineTests {
    @Test func scansEveryTranscriptIntoSevenDailyTotals() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date(timeIntervalSince1970: 1_757_700_000)
        let yesterday = now.addingTimeInterval(-24 * 3600)

        try (line(id: "m1", request: "r1", tokens: 100, at: now) + "\n"
            + line(id: "m2", request: "r2", tokens: 50, at: yesterday) + "\n")
            .write(
                to: fixture.root.appendingPathComponent("-Users-me-alpha/a.jsonl"),
                atomically: true,
                encoding: .utf8
            )
        // Duplicate of m1 in a second file: the message.id:requestId dedupe must drop it.
        try (line(id: "m3", request: "r3", tokens: 7, at: now) + "\n"
            + line(id: "m1", request: "r1", tokens: 100, at: now) + "\n")
            .write(
                to: fixture.root.appendingPathComponent("-Users-me-beta/b.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let sparkline = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL)
        let totals = await sparkline.dailyTotals(now: now)

        #expect(totals.count == 7)
        #expect(totals[6] == 107)
        #expect(totals[5] == 50)
        #expect(totals[0...4].allSatisfy { $0 == 0 })
        #expect(await sparkline.readCount == 2)
    }

    @Test func unchangedFilesAreNotReRead() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date(timeIntervalSince1970: 1_757_700_000)
        let first = fixture.root.appendingPathComponent("-Users-me-alpha/a.jsonl")
        let second = fixture.root.appendingPathComponent("-Users-me-beta/b.jsonl")
        try (line(id: "m1", request: "r1", tokens: 100, at: now) + "\n")
            .write(to: first, atomically: true, encoding: .utf8)
        try (line(id: "m2", request: "r2", tokens: 25, at: now) + "\n")
            .write(to: second, atomically: true, encoding: .utf8)

        let sparkline = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL)
        _ = await sparkline.dailyTotals(now: now)
        #expect(await sparkline.readCount == 2)

        let cached = await sparkline.dailyTotals(now: now)
        #expect(await sparkline.readCount == 2)
        #expect(cached[6] == 125)

        // Touching one file invalidates only that entry.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_757_800_000)],
            ofItemAtPath: second.path
        )
        let refreshed = await sparkline.dailyTotals(now: now)
        #expect(await sparkline.readCount == 3)
        #expect(refreshed[6] == 125)
    }

    @Test func coldStartReusesThePersistedCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date(timeIntervalSince1970: 1_757_700_000)
        try (line(id: "m1", request: "r1", tokens: 90, at: now) + "\n")
            .write(
                to: fixture.root.appendingPathComponent("-Users-me-alpha/a.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        let first = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL)
        _ = await first.dailyTotals(now: now)

        let second = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL)
        let totals = await second.dailyTotals(now: now)
        #expect(totals[6] == 90)
        #expect(await second.readCount == 0)
    }

    @Test func transcriptsOlderThanTheWindowAreNeverOpened() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date()
        let stale = now.addingTimeInterval(-30 * 24 * 3600)

        let recent = fixture.root.appendingPathComponent("-Users-me-alpha/a.jsonl")
        let old = fixture.root.appendingPathComponent("-Users-me-beta/old.jsonl")
        try (line(id: "m1", request: "r1", tokens: 100, at: now) + "\n")
            .write(to: recent, atomically: true, encoding: .utf8)
        try (line(id: "m2", request: "r2", tokens: 999, at: stale) + "\n")
            .write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: stale],
            ofItemAtPath: old.path
        )

        let sparkline = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL)
        let totals = await sparkline.dailyTotals(now: now)

        #expect(await sparkline.readCount == 1)
        #expect(totals[6] == 100)
        #expect(totals[0...5].allSatisfy { $0 == 0 })
    }

    @Test func linesThatAreNotAssistantTurnsAreSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date()
        let file = fixture.root.appendingPathComponent("-Users-me-alpha/a.jsonl")
        try ("""
        {"type":"mode","mode":"normal"}
        {"type":"user","timestamp":"\(timestamp(now))","message":{"role":"user"}}
        \(line(id: "m1", request: "r1", tokens: 64, at: now))

        """).write(to: file, atomically: true, encoding: .utf8)

        let sparkline = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL)
        let totals = await sparkline.dailyTotals(now: now)

        #expect(await sparkline.readCount == 1)
        #expect(totals[6] == 64)
    }

    /// The cache is megabytes and an idle poll finds nothing new, which is by far the common
    /// case: rewriting it every 15 minutes for no change is pure disk churn.
    @Test func unchangedScanDoesNotRewriteTheCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date(timeIntervalSince1970: 1_757_700_000)
        let file = fixture.root.appendingPathComponent("-Users-me-alpha/a.jsonl")
        try (line(id: "m1", request: "r1", tokens: 100, at: now) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let sparkline = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL)
        _ = await sparkline.dailyTotals(now: now)
        #expect(await sparkline.writeCount == 1)

        _ = await sparkline.dailyTotals(now: now)
        #expect(await sparkline.writeCount == 1)

        // A transcript that actually changed does earn a write.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_757_800_000)],
            ofItemAtPath: file.path
        )
        _ = await sparkline.dailyTotals(now: now)
        #expect(await sparkline.writeCount == 2)
    }

    /// A cold scan reads gigabytes; a caller that no longer wants the answer — the feature
    /// switched off, the app quitting — must not have to wait for the whole tree.
    @Test func cancelledScanStopsEarlyAndWritesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let now = Date(timeIntervalSince1970: 1_757_700_000)
        for index in 0..<40 {
            try (line(id: "m\(index)", request: "r\(index)", tokens: 10, at: now) + "\n")
                .write(
                    to: fixture.root.appendingPathComponent("-Users-me-alpha/\(index).jsonl"),
                    atomically: true,
                    encoding: .utf8
                )
        }

        // The reader blocks on the first file until the task has been cancelled, so the loop
        // is guaranteed to still be running when cancellation lands.
        let gate = DispatchSemaphore(value: 0)
        let sparkline = ClaudeSparkline(root: fixture.root, cacheURL: fixture.cacheURL) { url in
            gate.wait()
            return try Data(contentsOf: url)
        }

        let scan = Task.detached { await sparkline.dailyTotals(now: now) }
        scan.cancel()
        gate.signal()

        #expect(await scan.value == [])
        #expect(await sparkline.readCount < 40)
        #expect(await sparkline.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.cacheURL.path))
    }

    @Test func missingRootYieldsZeroes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let sparkline = ClaudeSparkline(
            root: fixture.root.appendingPathComponent("nowhere"),
            cacheURL: fixture.cacheURL
        )
        let totals = await sparkline.dailyTotals(now: Date())
        #expect(totals == [0, 0, 0, 0, 0, 0, 0])
    }
}
