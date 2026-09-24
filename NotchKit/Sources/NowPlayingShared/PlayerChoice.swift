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
/// shown player stays: what you were listening to, not what beeped last.
///
/// When the shown player is paused and another plays, the island switches at once, but the switch
/// is provisional: if the new player goes quiet before it has played for `takeoverDelay` and
/// nothing else plays, the island goes back to the last *established* player — one that has
/// played that long, or took the island any other way. Otherwise a 0.2 s sound in a Chrome tab
/// while the music is paused would take the island and, once silent, keep it: the reported bug
/// by another route. Used by the helper; pure so it is testable.
public struct PlayerChoice: Sendable {
    public struct Candidate: Equatable, Sendable {
        /// Names the player; unique within one `decide` call, since the history is keyed on it.
        /// The helper builds it: the bundle id, `<bundleID>#<pid>` for a second process of one
        /// app, `pid-<pid>` without a bundle id.
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
        /// The earliest moment a challenger will have played for `takeoverDelay`. No MediaRemote
        /// notification marks that moment, so the caller has to call `decide` again then. nil
        /// when no one is waiting.
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
    /// Non-nil exactly while `shownID` is provisional: the last established player, the one the
    /// island goes back to if the shown one goes quiet before it has played for `takeoverDelay`.
    private var returnTo: String?

    public init(takeoverDelay: TimeInterval = PlayerChoice.takeoverDelay) {
        self.takeoverDelay = takeoverDelay
    }

    public mutating func reset() {
        shownID = nil
        shownSince = .distantPast
        playingSince = [:]
        returnTo = nil
    }

    /// `candidates` in MediaRemote's list order, which breaks the remaining ties; `elected` is
    /// macOS's now-playing player.
    public mutating func decide(_ candidates: [Candidate], elected: String?, now: Date) -> Decision {
        // Read before the bookkeeping below forgets a paused player's start: a provisional player
        // that has played for the delay is established, even when this call reports it paused.
        if let shownID, hasPlayedForTheDelay(shownID, now: now) { returnTo = nil }

        var starts: [String: Date] = [:]
        for candidate in candidates where candidate.isPlaying {
            starts[candidate.id] = playingSince[candidate.id] ?? now
        }
        playingSince = starts

        let (decision, returnTo) = choose(candidates, elected: elected, now: now)
        self.returnTo = returnTo
        guard decision.playerID != shownID else { return decision }
        shownID = decision.playerID
        shownSince = now
        return Decision(playerID: decision.playerID, recheckAt: nil)
    }

    /// The decision, and what `returnTo` becomes with it.
    private func choose(_ candidates: [Candidate], elected: String?, now: Date) -> (Decision, returnTo: String?) {
        guard let shown = candidates.first(where: { $0.id == shownID }) else {
            // The shown player is gone, or there is none yet: the island is taken afresh, with
            // nothing to go back to.
            return (Decision(playerID: fallback(candidates, elected: elected), recheckAt: nil), nil)
        }
        let playing = candidates.filter(\.isPlaying)
        if shown.isPlaying {
            // A newcomer that takes over has played for the whole delay, so it is established.
            let decision = challenge(shown.id, by: playing, now: now)
            return (decision, decision.playerID == shown.id ? returnTo : nil)
        }
        if let player = pick(among: playing, elected: elected) {
            // The shown player is quiet and another plays: switch at once, but provisionally, so a
            // sound that stops within the delay hands the island back. A player that already has
            // the delay behind it is established at once. A provisional player replaced by another
            // keeps the original anchor: neither of them is what you were listening to.
            let anchor = hasPlayedForTheDelay(player, now: now) ? nil : returnTo ?? shown.id
            return (Decision(playerID: player, recheckAt: nil), anchor)
        }
        // Nothing plays. A provisional player hands the island back to the established one while
        // that is still listed; otherwise the shown player stays, paused.
        let kept = candidates.first { $0.id == returnTo }?.id ?? shown.id
        return (Decision(playerID: kept, recheckAt: nil), nil)
    }

    /// For when the shown player is gone or there is none yet: a playing player, else macOS's
    /// elected one, else the first listed.
    private func fallback(_ candidates: [Candidate], elected: String?) -> String? {
        if let player = pick(among: candidates.filter(\.isPlaying), elected: elected) { return player }
        if let elected, candidates.contains(where: { $0.id == elected }) { return elected }
        return candidates.first?.id
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

    /// Whether `id` has played without a break for `takeoverDelay`, by the starts recorded so far.
    /// The same sum as a takeover's readiness, so the two agree at the boundary.
    private func hasPlayedForTheDelay(_ id: String, now: Date) -> Bool {
        guard let start = playingSince[id] else { return false }
        return start.addingTimeInterval(takeoverDelay) <= now
    }

    /// Only called for playing candidates, which `decide` has always given a start.
    private func start(of player: Candidate) -> Date {
        playingSince[player.id] ?? .distantPast
    }
}
