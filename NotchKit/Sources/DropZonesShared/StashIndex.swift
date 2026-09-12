import Foundation

/// One file kept in the stash.
///
/// `storedPath` is our copy under `Stash/<UUID>/<name>`; `originalPath` is where
/// it came from when we know (file-URL drops), and `nil` for promise and raw
/// image drops that never had a place on disk. Originals are never moved or
/// deleted — the path is kept only so "Reveal in Finder" can prefer it.
public struct StashedFile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var storedPath: String
    public var bytes: Int64
    public var originalPath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        storedPath: String,
        bytes: Int64,
        originalPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.storedPath = storedPath
        self.bytes = bytes
        self.originalPath = originalPath
    }
}

/// The persisted stash: what is in it and when the pile started.
///
/// Kept as a pure value so the expiry and drop-action rules can be tested
/// without touching the real `~/Library/Application Support/Notch` directory —
/// `StashStore` is the only thing that reads or writes files.
public struct StashIndex: Codable, Equatable, Sendable {
    /// How long a stash lives, measured from ``stashedAt``: 24 hours.
    public static let ttl: TimeInterval = 86_400

    public var files: [StashedFile]
    /// When the current pile started. `nil` means nothing has been stashed, and
    /// an empty stash never expires because there is nothing to expire.
    public var stashedAt: Date?

    public init(files: [StashedFile] = [], stashedAt: Date? = nil) {
        self.files = files
        self.stashedAt = stashedAt
    }

    /// Sum of every stashed file's size, for the caption.
    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    /// Whether the pile has outlived its TTL. The boundary is inclusive: at
    /// exactly `stashedAt + ttl` the stash is gone, so a one-shot timer fired at
    /// that instant does clear it rather than re-arming itself for one more tick.
    public func isExpired(now: Date) -> Bool {
        guard let stashedAt else { return false }
        return now.timeIntervalSince(stashedAt) >= Self.ttl
    }

    /// Applies a drop.
    ///
    /// `.replace` starts a new pile, so the clock restarts with it. `.add` keeps
    /// the existing `stashedAt` on purpose: the TTL runs from the *first* drop,
    /// otherwise a stash topped up every few hours would never expire. Adding to
    /// an empty stash is the first drop, so it does start the clock.
    public mutating func apply(_ action: StashDropAction, adding: [StashedFile], now: Date) {
        switch action {
        case .replace:
            files = adding
            stashedAt = now
        case .add:
            files.append(contentsOf: adding)
            if stashedAt == nil { stashedAt = now }
        }
    }

    /// Empties the stash. Clearing `stashedAt` too is what keeps a TTL timer from
    /// being armed for a stash with nothing left in it.
    public mutating func removeAll() {
        files.removeAll()
        stashedAt = nil
    }
}
