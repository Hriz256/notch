import Foundation

/// Decides which player the island follows. The principle: the island shows what you hear.
///
/// macOS elects one now-playing player, the one that most recently *started* playing, and a
/// pause does not give the slot back. A 0.2 s sound in a Chrome tab takes the slot from Spotify
/// and keeps it while paused, so following the election shows a silent tab (and sends Play to
/// it) while Spotify plays. Here a playing player beats a paused one, and the election only
/// breaks ties.
///
/// The shown player keeps the island while it plays. A player that starts playing after it took
/// the island takes over only once it has played without a break for `takeoverDelay`, so a
/// notification sound or a hover preview does not flip the card. With nothing playing, the last
/// shown player stays: what you were listening to, not what beeped last. Used by the helper;
/// pure so it is testable.
public struct PlayerChoice: Sendable {
    public struct Candidate: Equatable, Sendable {
        /// The player's bundle identifier (`pid-<pid>` if it has none).
        public let id: String
        public let isPlaying: Bool

        public init(id: String, isPlaying: Bool) {
            self.id = id
            self.isPlaying = isPlaying
        }
    }

    public struct Decision: Equatable, Sendable {
        /// The player the island follows; nil when there is none.
        public let playerID: String?
        /// When a challenger will have played for `takeoverDelay`. No MediaRemote notification
        /// marks that moment, so the caller has to call `decide` again then. nil when no one is
        /// waiting.
        public let recheckAt: Date?

        public init(playerID: String?, recheckAt: Date?) {
            self.playerID = playerID
            self.recheckAt = recheckAt
        }
    }

    /// How long a newcomer has to play before it takes the island from a player that still plays.
    public static let takeoverDelay: TimeInterval = 3

    /// The player on the island as of the last `decide`.
    public private(set) var shownID: String?
    private let takeoverDelay: TimeInterval
    /// When `shownID` took the island. Only a player that started playing after this challenges
    /// it: one already playing then lost to it, and without this it would take the island a
    /// `takeoverDelay` later anyway.
    private var shownSince = Date.distantPast
    /// When each playing player started playing without a break. A pause forgets it, so a player
    /// that stops and starts again waits the whole delay again.
    private var playingSince: [String: Date] = [:]

    public init(takeoverDelay: TimeInterval = PlayerChoice.takeoverDelay) {
        self.takeoverDelay = takeoverDelay
    }

    public mutating func reset() {
        shownID = nil
        shownSince = .distantPast
        playingSince = [:]
    }

    /// `candidates` in MediaRemote's list order, which breaks the remaining ties; `elected` is
    /// macOS's now-playing player.
    public mutating func decide(_ candidates: [Candidate], elected: String?, now: Date) -> Decision {
        var starts: [String: Date] = [:]
        for candidate in candidates where candidate.isPlaying {
            starts[candidate.id] = playingSince[candidate.id] ?? now
        }
        playingSince = starts

        let decision = choose(candidates, elected: elected, now: now)
        guard decision.playerID != shownID else { return decision }
        shownID = decision.playerID
        shownSince = now
        return Decision(playerID: decision.playerID, recheckAt: nil)
    }

    private func choose(_ candidates: [Candidate], elected: String?, now: Date) -> Decision {
        let playing = candidates.filter(\.isPlaying)
        if let shown = candidates.first(where: { $0.id == shownID }) {
            if shown.isPlaying { return challenge(shown.id, by: playing, now: now) }
            return Decision(playerID: pick(among: playing, elected: elected) ?? shown.id, recheckAt: nil)
        }
        if let player = pick(among: playing, elected: elected) {
            return Decision(playerID: player, recheckAt: nil)
        }
        if let elected, candidates.contains(where: { $0.id == elected }) {
            return Decision(playerID: elected, recheckAt: nil)
        }
        return Decision(playerID: candidates.first?.id, recheckAt: nil)
    }

    /// Keeps the playing `shown` player unless a challenger has played for the whole delay.
    private func challenge(_ shown: String, by playing: [Candidate], now: Date) -> Decision {
        let challengers = playing.filter { $0.id != shown && start(of: $0) > shownSince }
        // Readiness and `recheckAt` use the same sum, so a `decide` at `recheckAt` does take over.
        let ready = challengers.filter { start(of: $0).addingTimeInterval(takeoverDelay) <= now }
        if let taker = latestStarted(ready) { return Decision(playerID: taker, recheckAt: nil) }
        let recheckAt = challengers.map { start(of: $0).addingTimeInterval(takeoverDelay) }.min()
        return Decision(playerID: shown, recheckAt: recheckAt)
    }

    /// `elected` if it is among `players`, otherwise the one that started playing last.
    private func pick(among players: [Candidate], elected: String?) -> String? {
        if let elected, players.contains(where: { $0.id == elected }) { return elected }
        return latestStarted(players)
    }

    /// Ties keep list order: `max(by:)` keeps the first of equal elements.
    private func latestStarted(_ players: [Candidate]) -> String? {
        players.max { start(of: $0) < start(of: $1) }?.id
    }

    /// Only called for playing candidates, which `decide` has always given a start.
    private func start(of player: Candidate) -> Date {
        playingSince[player.id] ?? .distantPast
    }
}
