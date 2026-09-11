import CodeAgentShared
import Foundation

/// Seven daily token totals scanned out of `~/.claude/projects/**/*.jsonl`.
///
/// There can be thousands of transcripts, so parsed entries are cached on disk keyed by
/// path + modification date and only changed files are re-read. Subagent transcripts are
/// included the way ccusage includes them — double counting is prevented by the
/// `message.id:requestId` dedupe in `ClaudeUsageLog`, not by excluding files.
public actor ClaudeSparkline {
    /// Number of files actually read from disk, across all scans. Test seam for the cache.
    public private(set) var readCount = 0

    private let root: URL
    private let cacheURL: URL
    private let reader: @Sendable (URL) throws -> String
    private let logger = UsageLog.logger("sparkline")

    private var cache: [String: CachedFile]?

    private struct CachedFile: Codable {
        var mtime: Date
        var entries: [CachedEntry]
    }

    private struct CachedEntry: Codable {
        var key: String?
        var tokens: Int
        var timestamp: Date

        init(_ entry: ClaudeUsageLog.Entry) {
            key = entry.key
            tokens = entry.tokens
            timestamp = entry.timestamp
        }

        var entry: ClaudeUsageLog.Entry {
            ClaudeUsageLog.Entry(key: key, tokens: tokens, timestamp: timestamp)
        }
    }

    public init(
        root: URL,
        cacheURL: URL,
        reader: @escaping @Sendable (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    ) {
        self.root = root
        self.cacheURL = cacheURL
        self.reader = reader
    }

    /// Daily totals ending on the day containing `now`, oldest first. Always `days` long.
    public func dailyTotals(now: Date, days: Int = 7) async -> [Double] {
        var cache = cache ?? loadCache()
        var fresh: [String: CachedFile] = [:]
        var entries: [ClaudeUsageLog.Entry] = []

        for file in transcripts() {
            let path = file.path
            let mtime = modificationDate(of: file)
            if let cached = cache[path], let mtime, cached.mtime == mtime {
                fresh[path] = cached
                entries.append(contentsOf: cached.entries.map(\.entry))
                continue
            }

            guard let contents = try? reader(file) else { continue }
            readCount += 1
            let parsed = contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { ClaudeUsageLog.entry(fromLine: String($0)) }
            entries.append(contentsOf: parsed)
            if let mtime {
                fresh[path] = CachedFile(mtime: mtime, entries: parsed.map(CachedEntry.init))
            }
        }

        // Files that disappeared drop out of the cache rather than growing it forever.
        cache = fresh
        self.cache = cache
        save(cache)

        return ClaudeUsageLog.dailyTotals(
            entries: entries,
            days: days,
            endingAt: now,
            calendar: .current
        )
    }

    // MARK: - Filesystem

    private func transcripts() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
    }

    private func modificationDate(of file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Cache file

    private func loadCache() -> [String: CachedFile] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedFile].self, from: data)
        else { return [:] }
        return decoded
    }

    private func save(_ cache: [String: CachedFile]) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            logger.debug("could not write sparkline cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
