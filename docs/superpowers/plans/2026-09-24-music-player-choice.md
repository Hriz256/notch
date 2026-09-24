# Music: follow the player the user hears — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The island follows the player that is actually playing (sticky, with a 3 s takeover for newcomers) instead of macOS's elected now-playing player, and its commands go to that player. Spec: `docs/superpowers/specs/2026-09-24-music-player-choice-design.md` — read §2 (the rule) and §3 (verified signatures) before starting.

**Architecture:** A pure `PlayerChoice` state machine in `NowPlayingShared` decides which player to follow; the XPC helper (`Helper/`) gains optional MediaRemote per-client symbols, feeds `PlayerChoice` on every refresh, publishes the chosen client's info and routes commands to it. App side, XPC protocol and snapshot format are unchanged.

**Tech Stack:** Swift 6 (language mode 6, strict concurrency), Swift Testing, `dlopen`ed private `MediaRemote.framework`. XcodeGen (`project.yml`) for the app; SwiftPM (`NotchKit/Package.swift`) for the modules.

## Global Constraints

- Branch `fix/music-player-choice` (already checked out). Commit after each task; messages `fix(Music): …` / `test(Music): …`, ending with the line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Do not push. Do not touch the untracked screenshots in the repo root.
- **Never build into `build/`** — the user's running Notch lives there and relinking it in place can kill the running app. Build the app with `-derivedDataPath build-fix` (gitignored by `/build-*/`). Do not launch, quit or kill Notch or NotchHelper; the lead does the live check.
- Do not send any MediaRemote command while testing (it would pause the user's music).
- Tests: Swift Testing (`@Test`, `#expect`), deterministic dates, no sleeping. Run with `cd NotchKit && swift test`.
- Match the surrounding code: doc comments explain *why*, `@unchecked Sendable` with a comment naming the confinement, `Logger(subsystem: "app.notch", category: "helper.monitor")`.
- MediaRemote block signatures are exactly those in spec §3. In particular `MRMediaRemoteGetPlaybackStateForClient`'s block takes **one** `UInt32` (a second parameter crashes), and the info block is read as `(CFDictionary?) -> Void`.

---

### Task 1: `PlayerChoice` — which player the island follows

**Files:**
- Create: `NotchKit/Sources/NowPlayingShared/PlayerChoice.swift`
- Create: `NotchKit/Tests/NowPlayingSharedTests/PlayerChoiceTests.swift`

**Interface (exact):**

```swift
public struct PlayerChoice: Sendable {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let isPlaying: Bool
        public init(id: String, isPlaying: Bool)
    }
    public struct Decision: Equatable, Sendable {
        public let playerID: String?
        public let recheckAt: Date?
        public init(playerID: String?, recheckAt: Date?)
    }
    public static let takeoverDelay: TimeInterval = 3
    public private(set) var shownID: String?
    public init(takeoverDelay: TimeInterval = PlayerChoice.takeoverDelay)
    public mutating func decide(_ candidates: [Candidate], elected: String?, now: Date) -> Decision
    public mutating func reset()
}
```

**Behaviour (spec §2), in the order `decide` applies it:**

1. Bookkeeping: for every candidate that plays, remember when it started playing continuously (keep an existing start; set `now` if new). Forget the start of every candidate that does not play and of every id no longer listed.
2. `pick(among:)` = `elected` if it is among them; otherwise the one with the latest continuous-play start; ties keep list order.
3. If the shown player is still listed:
   - and it plays: *challengers* are the other playing candidates whose start is **later** than the moment the shown player took the island. A challenger whose start is `≥ takeoverDelay` before `now` takes the island (if several are ready, the latest start). Otherwise keep the shown player and set `recheckAt` = the earliest `start + takeoverDelay` among challengers (nil if none).
   - and it does not play: if any candidate plays, switch to `pick(among: playing)`; else keep it.
4. If there is no shown player or it is no longer listed: `pick(among: playing)` if any plays; else `elected` if it is listed; else the first candidate; else nil.
5. Whenever the chosen id differs from `shownID`, record `now` as the moment it took the island. `recheckAt` is nil after a switch.
6. `reset()` forgets everything (shown id, when it took the island, all starts).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import NowPlayingShared

struct PlayerChoiceTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let spotify = "com.spotify.client"
    let chrome = "com.google.Chrome"

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func c(_ id: String, _ playing: Bool) -> PlayerChoice.Candidate { .init(id: id, isPlaying: playing) }

    @Test func nothingPlayingFollowsTheElectedPlayer() {
        var choice = PlayerChoice()
        let d = choice.decide([c(spotify, false), c(chrome, false)], elected: chrome, now: t0)
        #expect(d == .init(playerID: chrome, recheckAt: nil))
    }

    /// The reported bug: a paused Chrome tab is elected while Spotify plays.
    @Test func aPlayingPlayerBeatsAPausedElectedOne() {
        var choice = PlayerChoice()
        let d = choice.decide([c(chrome, false), c(spotify, true)], elected: chrome, now: t0)
        #expect(d.playerID == spotify)
    }

    @Test func bothPlayingWithNoHistoryFollowsTheElectedPlayer() {
        var choice = PlayerChoice()
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: t0).playerID == chrome)
    }

    @Test func aBriefSoundDoesNotTakeTheIsland() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        let during = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10))
        #expect(during == .init(playerID: spotify, recheckAt: at(13)))
        let after = choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: at(10.2))
        #expect(after == .init(playerID: spotify, recheckAt: nil))
    }

    @Test func aNewcomerTakesTheIslandAfterPlayingForTheDelay() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10)).playerID == spotify)
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(12.9)).playerID == spotify)
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(13)) == .init(playerID: chrome, recheckAt: nil))
    }

    @Test func aNewcomerThatPausesLosesItsHeadStart() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        _ = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10))
        _ = choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: at(12))
        let again = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(14))
        #expect(again == .init(playerID: spotify, recheckAt: at(17)))
    }

    @Test func aPlayerAlreadyPlayingWhenTheShownOneTookOverIsNotAChallenger() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: t0)
        let later = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(60))
        #expect(later == .init(playerID: chrome, recheckAt: nil))
    }

    @Test func pausingTheShownPlayerHandsTheIslandToAPlayingOne() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        _ = choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(10))
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: chrome, now: at(13)).playerID == chrome)
        #expect(choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: at(20)).playerID == spotify)
    }

    @Test func nothingPlayingKeepsTheLastShownPlayer() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true), c(chrome, false)], elected: chrome, now: t0)
        #expect(choice.decide([c(spotify, false), c(chrome, false)], elected: chrome, now: at(5)).playerID == spotify)
    }

    @Test func theShownPlayerQuittingFallsBackToAPlayingOneThenTheElected() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, false)], elected: spotify, now: t0)
        #expect(choice.decide([c(chrome, true)], elected: chrome, now: at(1)).playerID == chrome)
        var idle = PlayerChoice()
        _ = idle.decide([c(spotify, false)], elected: spotify, now: t0)
        #expect(idle.decide([c(chrome, false), c("com.apple.Music", false)], elected: "com.apple.Music", now: at(1)).playerID == "com.apple.Music")
        #expect(idle.decide([c(chrome, false)], elected: nil, now: at(2)).playerID == chrome)
    }

    @Test func noCandidatesChoosesNothing() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        #expect(choice.decide([], elected: nil, now: at(1)) == .init(playerID: nil, recheckAt: nil))
        #expect(choice.shownID == nil)
    }

    @Test func whenTheShownPlayerQuitsTheLatestStartedPlayingOneWins() {
        var choice = PlayerChoice()
        let music = "com.apple.Music"
        _ = choice.decide([c(music, true)], elected: music, now: t0)
        _ = choice.decide([c(music, true), c(spotify, true)], elected: music, now: at(1))
        _ = choice.decide([c(music, true), c(spotify, true), c(chrome, true)], elected: music, now: at(2))
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: nil, now: at(2.5)).playerID == chrome)
    }

    @Test func equalStartsFallBackToListOrder() {
        var choice = PlayerChoice()
        #expect(choice.decide([c(spotify, true), c(chrome, true)], elected: nil, now: t0).playerID == spotify)
    }

    @Test func resetForgetsTheShownPlayer() {
        var choice = PlayerChoice()
        _ = choice.decide([c(spotify, true)], elected: spotify, now: t0)
        choice.reset()
        #expect(choice.shownID == nil)
        #expect(choice.decide([c(spotify, false), c(chrome, false)], elected: chrome, now: at(1)).playerID == chrome)
    }
}
```

- [ ] **Step 2:** `cd NotchKit && swift test --filter PlayerChoiceTests` — expect a compile failure (type missing).
- [ ] **Step 3:** Implement `PlayerChoice.swift` per the behaviour list. Doc comment on the type: the principle ("the island shows what you hear") and why macOS's election is not enough (a pause does not give the slot back). Keep it small; no Foundation beyond `Date`/`TimeInterval`.
- [ ] **Step 4:** `swift test --filter PlayerChoiceTests` — all pass; then the full `swift test` — all pass.
- [ ] **Step 5:** Commit `fix(Music): PlayerChoice decides which player the island follows`.

---

### Task 2: the helper follows `PlayerChoice` and commands its player

**Files:**
- Modify: `Helper/MediaRemoteBridge.swift`
- Modify: `Helper/NowPlayingMonitor.swift`

**Bridge (`MediaRemoteBridge`)** — add, all **optional** (`nil` when `dlsym` misses), with doc comments that name the spike (`spikes/MediaRemoteSpike`) as the source of the signatures:

```swift
typealias GetLocalOriginFn = @convention(c) () -> Unmanaged<AnyObject>?
typealias GetClientsFn = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
typealias StateForClientFn = @convention(c) (AnyObject?, AnyObject?, DispatchQueue, @escaping @convention(block) (UInt32) -> Void) -> Void
typealias InfoForClientFn = @convention(c) (AnyObject?, AnyObject?, Bool, DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
typealias SendToClientFn = @convention(c) (UInt32, CFDictionary?, AnyObject?, AnyObject?, UInt32, DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Bool
```

Symbols: `MRMediaRemoteGetLocalOrigin`, `MRMediaRemoteGetNowPlayingClients`, `MRMediaRemoteGetPlaybackStateForClient`, `MRMediaRemoteGetNowPlayingInfoForClient`, `MRMediaRemoteSendCommandToClient`, plus `MRNowPlayingClientGetProcessIdentifier` (`@convention(c) (AnyObject?) -> Int32`) for the `pid-<pid>` fallback id. Group the five per-client functions in one optional struct (e.g. `PerClient`) so the monitor tests one optional, not five. `Command` gains `case seekToPlaybackPosition = 24`. Add `static let playbackPositionOption = "kMRMediaRemoteOptionPlaybackPosition"`, the playback state constant `playing = 1`, and the notification names `kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification`, `kMRMediaRemotePlayerIsPlayingDidChangeNotification`, `kMRMediaRemotePlayerPlaybackStateDidChangeNotification`, `kMRMediaRemoteNowPlayingApplicationDidUnregister`. Update the type's doc comment (which symbols are required vs optional).

**Monitor (`NowPlayingMonitor`):**

- [ ] **Step 1:** Keep today's refresh as `refreshElectedOnly()` (unchanged behaviour) for when the per-client symbols are missing; log that once at `.notice`.
- [ ] **Step 2:** New `refresh()` when available (all on `queue`, every hop guarded by `current == epoch`): `GetNowPlayingClients` → `GetNowPlayingClient` for the elected bundle id (nil-safe as today) → `GetPlaybackStateForClient` for every client in parallel (`DispatchGroup`, results stored by index, `notify` on `queue`) → `choice.decide(candidates, elected:, now:)` → store the chosen `MRClient` in `followedClient` (nil when none) → `GetNowPlayingInfoForClient(client, origin, true, queue)` → `publish(info:isPlaying:bundleID:)` with `isPlaying = state == playing`. With no chosen client, `publish(info: [:], isPlaying: false, bundleID: nil)` (the card goes, as today with no client). The origin comes from `GetLocalOrigin()` (unretained; take it per refresh or keep a strong reference — either is fine, say which in a comment).
- [ ] **Step 3:** `recheckAt` → a dedicated `pendingRecheck: DispatchWorkItem?` (cancel the previous one; schedule `refresh()` at `recheckAt` + 50 ms). The debounce's `pendingRefresh` must not cancel it.
- [ ] **Step 4:** Artwork follow-up (spec §4.2): in the per-client path, when the chosen info has a non-empty title but no `ArtworkData`, schedule one `refresh()` 1 s later unless one was already scheduled for this track key (`bundleID + title + artist`); remember the last key it was scheduled for.
- [ ] **Step 5:** In `publish`, when `bundleID` differs from `lastPublished?.sourceBundleID`, clear `lastIsPlaying`, `pauseObservedAt`, `resumeObservedAt` before `recordTransportFlip`, with a one-line comment (a flip is one player's). When the followed id changes, log at `.notice`: `Following <id> (elected <id or ->)`.
- [ ] **Step 6:** Commands: `send(_:)` uses `SendCommandToClient(command, nil, origin, followedClient, 0, queue) { _ in }` when both the per-client functions and `followedClient` exist; else today's `sendCommand`. The `!ok` handling (dedup reset) stays. `seek(to:)` likewise with command 24 and `[playbackPositionOption: seconds] as CFDictionary`; else today's `setElapsed`. Both still `scheduleRefresh()`.
- [ ] **Step 7:** Observe the four new notification names alongside today's three: the two `…PlayerIsPlaying…`/`…PlayerPlaybackState…` with `immediate`, the other two with `debounce`.
- [ ] **Step 8:** `requestFullState()` and `start(token:)`'s dedup reset do **not** reset `choice` (a reconnecting app must not see the island jump to the elected player); the memory-pressure handler leaves it alone too.
- [ ] **Step 9:** Build: `xcodegen generate && xcodebuild -project Notch.xcodeproj -scheme Notch -configuration Debug -derivedDataPath build-fix build 2>&1 | tail -5` — `** BUILD SUCCEEDED **`, no new warnings in `Helper/` (`grep -E "Helper/.*warning"` on the full log). Then `cd NotchKit && swift test` — all pass.
- [ ] **Step 10:** Commit `fix(Music): the island follows the player you hear, not the one macOS elected`. Body: the root cause in two sentences (spec §1) and the rule in one.

---

### Task 3: the marquee title never scrolls out of sight

**Bug (spec §6):** on the expanded card a long title (e.g. `ScreenRecording_09-24-2026 11-15-26_1.mov - Google Диск`, 392.5 pt in a 240 pt slot) is blank for seconds at a time. `MarqueeText.restart()` runs twice on appear (once for `containerWidth`, once for `textWidth`) and every run starts another `withAnimation(….repeatForever)`. SwiftUI animations are additive and a repeat-forever one never ends, so the two loops stack: measured with an `Animatable` probe, the rendered offset ran from **+424.5** to −112 instead of 0 to −424.5 — the text sat right of the slot for ~6 s, crawled back, and left again. The comment that "assigning `offset` outside an animation also cancels the previous loop" is wrong, and resetting through a `Transaction` with `disablesAnimations` does not cancel it either (measured: same +424.5).

**Fix:** the loop is a `keyframeAnimator(initialValue:repeating:)` that owns the offset — hold 1.2 s at 0, then linear to `-(textWidth + 32)` at `speed` pt/s, repeat — and is keyed with `.id` on the text and the distance, so a new title or a new width starts one fresh loop from 0 and nothing can stack. Measured the same way: the rendered offset stays within [−distance, 0], and a title change restarts at 0.

**Files:**
- Modify: `NotchKit/Sources/MusicFeature/Views/MarqueeText.swift` (the only file; both call sites — `MusicExpandedView` and the track-change peek in `MusicCompactViews` — keep their current initialiser calls unchanged)

- [ ] **Step 1:** Replace the `offset` state, `restart()` and the four `onChange` restarts with the keyframe loop. The resulting `body` and helpers (keep `edgeFade`, `label`, the public properties and their defaults, and adapt the doc comments to the new mechanism — they must say *why* the loop is keyed, and must not repeat the wrong claim about cancelling):

```swift
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var needsScroll: Bool { textWidth > containerWidth + 1 }
    /// One loop's travel: the title plus the gap to its copy, so the copy lands exactly where the
    /// title started and the jump back to 0 is invisible.
    private var distance: CGFloat { textWidth + Self.gap }
    private static let gap: CGFloat = 32
    private static let pause: TimeInterval = 1.2

    var body: some View {
        GeometryReader { geo in
            Group {
                if needsScroll {
                    HStack(spacing: Self.gap) { label; label }
                        .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { row, x in
                            row.offset(x: x)
                        } keyframes: { _ in
                            KeyframeTrack {
                                LinearKeyframe(0, duration: Self.pause)
                                LinearKeyframe(-distance, duration: distance / speed)
                            }
                        }
                        .id(ScrollKey(text: text, distance: distance))
                } else {
                    label
                }
            }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
        }
        .frame(height: height)
        .clipped()
        .mask(edgeFade)
    }

    /// What a scroll loop runs for. A new title or a new distance gets a new identity, which
    /// starts one fresh loop from 0 instead of layering a second animation over the first.
    private struct ScrollKey: Hashable {
        let text: String
        let distance: CGFloat
    }
```

- [ ] **Step 2:** `cd NotchKit && swift build 2>&1 | grep -E "warning|error"` — nothing from `MarqueeText.swift`; then `swift test` — all pass (there are no view tests; the covering check is the probe below).
- [ ] **Step 3:** Probe the real file. Copy `NotchKit/Sources/MusicFeature/Views/MarqueeText.swift` into a scratch directory next to a `main.swift` that hosts `MarqueeText(text: "ScreenRecording_09-24-2026 11-15-26_1.mov - Google Диск").frame(width: 240)` in an `NSHostingView` inside a borderless `NSWindow` with `alphaValue = 0`, `ignoresMouseEvents = true`, `orderFrontRegardless()`, runs `NSApplication` for 20 s, and changes the title to another long one at 3 s. In the copy only, replace `row.offset(x: x)` with a modifier that prints `x` and applies the offset. Build with `swiftc -O main.swift MarqueeText.swift -o probe`, run it, and record in the report: the number of printed frames, the min/max rendered offset before and after the title change (expected: within [−distance, 0], never positive), and the offset right after the change (0). Delete the scratch directory afterwards; nothing of the probe is committed.
- [ ] **Step 4:** Commit `fix(Music): a long title no longer scrolls out of sight on the card`. Body: the stacking cause in two sentences with the measured +424.5, and the fix in one.

---

## Verification (lead, after all tasks)

1. With a paused Chrome video elected and Spotify playing (the reported state): swap in the new helper, and `log stream --level debug --style compact --predicate 'subsystem == "app.notch"'` must show `Following com.spotify.client (elected com.google.Chrome)` and a `Snapshot:` with Spotify's title and artwork bytes.
2. The user checks the island visually: Spotify's track, cover, pause glyph; the island's pause pauses Spotify, not Chrome.
3. A 0.2 s sound or a short video in Chrome while Spotify plays does not take the island; a video played for > 3 s does, and pausing it hands the island back to Spotify.
4. A long title (the Chrome item, or a long Spotify title) is readable on the expanded card: it waits 1.2 s, scrolls left, and loops without ever leaving the slot empty.
