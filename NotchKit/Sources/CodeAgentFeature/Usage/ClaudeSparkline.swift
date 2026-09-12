import CodeAgentShared
import Foundation

/// Seven daily token totals for the usage sparkline.
///
/// A seam so `UsageRefreshCoordinator` can be driven by a fake in tests; the only
/// production conformance is `ClaudeSparkline`.
public protocol UsageSparkline: Sendable {
    func dailyTotals(now: Date, days: Int) async -> [Double]
}

/// Seven daily token totals scanned out of `~/.claude/projects/**/*.jsonl`.
///
/// There can be thousands of transcripts, so the scan is narrowed three ways: files whose
/// modification date predates the window are skipped without being opened, parsed entries
/// are cached on disk keyed by path + modification date so only changed files are re-read,
/// and within a file only lines carrying `"type":"assistant"` reach the JSON parser.
/// Subagent transcripts are included the way ccusage includes them — double counting is
/// prevented by the `message.id:requestId` dedupe in `ClaudeUsageLog`, not by excluding
/// files.
public actor ClaudeSparkline: UsageSparkline {
    /// Number of files actually read from disk, across all scans. Test seam for the cache.
    public private(set) var readCount = 0
    /// Number of times the cache file was rewritten. Test seam for the "nothing changed,
    /// nothing to write" skip.
    public private(set) var writeCount = 0

    private let root: URL
    private let cacheURL: URL
    private let reader: @Sendable (URL) throws -> Data
    private let logger = UsageLog.logger("sparkline")

    private var cache: [String: CachedFile]?

    /// A transcript line only counts when it carries this, so the substring check below
    /// keeps the ~99 % of lines that are not assistant turns out of `JSONSerialization`.
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    private struct CachedFile: Codable, Equatable {
        var mtime: Date
        var entries: [CachedEntry]
    }

    private struct CachedEntry: Codable, Equatable {
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
        reader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0, options: .mappedIfSafe) }
    ) {
        self.root = root
        self.cacheURL = cacheURL
        self.reader = reader
    }

    /// Daily totals ending on the day containing `now`, oldest first. Always `days` long.
    ///
    /// Cancellable: the walk can read gigabytes on a cold cache, so a caller that no longer
    /// wants the answer — the feature being switched off, the app quitting — gets out at the
    /// next file rather than at the end of the tree.
    public func dailyTotals(now: Date, days: Int = 7) async -> [Double] {
        let cache = cache ?? loadCache()
        var fresh: [String: CachedFile] = [:]
        var entries: [ClaudeUsageLog.Entry] = []

        // A transcript last written before the window opened cannot hold an entry inside
        // it, so it is never opened. One extra day absorbs time-zone skew.
        let cutoff = now.addingTimeInterval(-Double(days + 1) * 86_400)

        for file in transcripts(modifiedAtOrAfter: cutoff) {
            if Task.isCancelled { return [] }
            let path = file.url.path
            if let cached = cache[path], let mtime = file.mtime, cached.mtime == mtime {
                fresh[path] = cached
                entries.append(contentsOf: cached.entries.map(\.entry))
                continue
            }

            guard let data = try? reader(file.url) else { continue }
            readCount += 1
            let parsed = Self.parse(data)
            entries.append(contentsOf: parsed)
            if let mtime = file.mtime {
                fresh[path] = CachedFile(mtime: mtime, entries: parsed.map(CachedEntry.init))
            }
        }

        // Files that disappeared — or aged out of the window — drop out of the cache
        // rather than growing it forever. A poll that found nothing new writes nothing:
        // the cache is megabytes, and the idle case is by far the common one.
        self.cache = fresh
        if fresh != cache { save(fresh) }

        return ClaudeUsageLog.dailyTotals(
            entries: entries,
            days: days,
            endingAt: now,
            calendar: .current
        )
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) -> [ClaudeUsageLog.Entry] {
        var entries: [ClaudeUsageLog.Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.range(of: assistantMarker) != nil,
                  let entry = ClaudeUsageLog.entry(fromLine: String(decoding: line, as: UTF8.self))
            else { continue }
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Filesystem

    private struct Transcript {
        var url: URL
        /// `nil` when the modification date could not be read; such a file is always
        /// scanned and never cached.
        var mtime: Date?
    }

    private func transcripts(modifiedAtOrAfter cutoff: Date) -> [Transcript] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [Transcript] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            if values?.isRegularFile == false { continue }
            let mtime = values?.contentModificationDate
            if let mtime, mtime < cutoff { continue }
            result.append(Transcript(url: url, mtime: mtime))
        }
        return result
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
            writeCount += 1
        } catch {
            logger.debug("could not write sparkline cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
