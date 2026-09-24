# Notch — Music: which player the island follows

**Date:** 2026-09-24
**Status:** approved 2026-09-24 (rule: "давай так"; spike: go-ahead after it passed)
**Bug:** Spotify was playing, yet the island showed a paused, 4-second Google Drive screen recording from Chrome with a placeholder cover, and its Play button started that video. Screenshots `Screenshot 2026-09-24 at 13.28.49.png` and `… 13.50.56.png`.

## 1. Root cause

The helper asks MediaRemote only for the *elected* now-playing player (`MRMediaRemoteGetNowPlayingInfo`, `…ApplicationIsPlaying`, `…GetNowPlayingClient`). macOS elects the player that most recently **started** playing, and a pause does not give the slot back: a 0.2 s sound in a Chrome tab at 13:21:41 took the slot from Spotify and kept it while paused, because Spotify never started again. The helper then published Chrome's paused item, and `MRMediaRemoteSendCommand` sent the island's Play to Chrome (MediaRemote log: `Command = <TogglePlayPause> … for com.google.Chrome`).

It also went deaf to Spotify: while Chrome is elected, a Spotify track change posts only the per-player `kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification`; the elected-level `kMRMediaRemoteNowPlayingInfoDidChangeNotification` the helper listens to does not fire for it.

The AppleScript fallback never engages: it takes over only when the helper is *silent*, and here the helper keeps sending snapshots.

## 2. The rule

Principle: **the island shows what you hear, and its buttons control what it shows.**

1. The shown player is sticky: while it plays, it keeps the island.
2. If the shown player is paused or stopped and another plays, the island switches to the playing one at once. The switch is **provisional** until the new player has played continuously for 3 s: if it goes quiet before that and nothing else plays, the island returns to the last *established* player, if that app is still running (a 0.2 s sound while the music is paused must not leave the sound's tab on the island). A player is established once it has played continuously for 3 s, or when it took the island by any other rule; a player that already had 3 s of continuous play when the switch happened is established at once. *(Added 2026-09-24 after the final review — "Возвращать остров".)*
3. If both play, a newcomer — a player that started playing *after* the shown one took the island — takes it only once it has played **continuously for 3 s** (`PlayerChoice.takeoverDelay`). A notification sound, a hover preview, 0.2 s of a video never take it.
4. If nothing plays, the last shown player stays (paused): what you were listening to, not what beeped last.
5. If the shown player's app goes away: a playing player if there is one; otherwise macOS's elected player; otherwise the first one listed; otherwise nothing (the card goes).
6. With no history (first decision, or after a reset) and several players playing, macOS's elected player wins; among players that are not elected, the one that most recently started.

Play/pause/next/previous/seek go to the shown player, not to the elected one.

| Scenario | Before | After |
|---|---|---|
| Spotify plays, a Chrome tab plays 0.2 s and pauses | Chrome, paused; Play starts the video | Spotify (rule 3) |
| Pause Spotify, start a YouTube video | YouTube | YouTube at once (rule 2) |
| Spotify plays, a YouTube video plays 10 s on top | YouTube | YouTube after 3 s (rule 3) |
| … then the video is paused | YouTube, paused | Spotify, still playing (rule 2) |
| Everything paused | Whoever started last | What was shown last (rule 4) |
| Spotify paused, a Chrome tab plays 0.2 s | Chrome, paused | Chrome for 0.2 s, then Spotify, paused (rule 2, provisional) |
| Spotify plays, a video starts, Spotify is paused 1 s later, the video plays on | YouTube | YouTube at once, established after 3 s of play; pausing it later keeps it (rule 4) |
| … or Spotify is quit instead | YouTube | YouTube (rule 5); nothing to return to |

Not solved here: the hardware media keys go to macOS's elected player, not through the island (Seam ships a `MediaKeyInterceptor`; a separate step if wanted). No setting, no opt-out.

## 3. Spike (2026-09-24, macOS 26.5, `spikes/MediaRemoteSpike`)

Signatures recovered with `dyld_info -disassemble` on MediaRemote (no debugger), then called from an ad-hoc-signed tool whose bundle id is `com.apple.controlcenter.NotchSpike`. All work under the same entitlement bypass as the helper:

| Symbol | C signature | Verified |
|---|---|---|
| `MRMediaRemoteGetLocalOrigin` | `id (void)` (unretained) | returns an `MROrigin` |
| `MRMediaRemoteGetNowPlayingClients` | `void (dispatch_queue_t, void (^)(NSArray<MRClient *> *))` | Chrome and Spotify both listed while Chrome is elected |
| `MRNowPlayingClientGetBundleIdentifier` | already used; works on `MRClient` list elements | ✓ |
| `MRMediaRemoteGetPlaybackStateForClient` | `void (MRClient *, MROrigin *, dispatch_queue_t, void (^)(uint32_t state))` — **one** argument: declaring a second one crashes | Chrome `2` (paused), Spotify `1` (playing) |
| `MRMediaRemoteGetNowPlayingInfoForClient` | `void (MRClient *, MROrigin *, Boolean withArtwork, dispatch_queue_t, void (^)(CFDictionaryRef))` | Spotify's title/artist/duration/elapsed/rate and 176 KB of artwork while Chrome is elected (right after a track change the bytes can be missing for a moment — the helper already copes) |
| `MRMediaRemoteSendCommandToClient` | `Boolean (uint32_t cmd, CFDictionaryRef options, MROrigin *, MRClient *, uint32_t appOptions, dispatch_queue_t, void (^)(id))` | `Pause` delivered to Chrome only (MediaRemote log) |
| command `24` = `SeekToPlaybackPosition`, option `kMRMediaRemoteOptionPlaybackPosition` (seconds, `Double`) | via `SendCommandToClient` | Chrome's elapsed went 4.04 → 1.0 |
| `kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification`, `kMRMediaRemotePlayerIsPlayingDidChangeNotification`, `kMRMediaRemotePlayerPlaybackStateDidChangeNotification`, `kMRMediaRemoteNowPlayingApplicationDidUnregister` | posted after `MRMediaRemoteRegisterForNowPlayingNotifications`; userInfo carries the player path | Spotify's track change seen while Chrome was elected |

## 4. Design

### 4.1 `NowPlayingShared.PlayerChoice` (new, pure)

A value type the helper owns and feeds on every refresh. It holds the shown player's id, when it took the island, and when each player started playing continuously.

```swift
public struct PlayerChoice: Sendable {
    public struct Candidate: Equatable, Sendable { public let id: String; public let isPlaying: Bool }
    public struct Decision: Equatable, Sendable {
        public let playerID: String?
        /// The earliest moment the choice can change without any MediaRemote notification — a
        /// challenger's takeover delay running out. nil when nothing is pending.
        public let recheckAt: Date?
    }
    public static let takeoverDelay: TimeInterval = 3
    public private(set) var shownID: String?
    public init(takeoverDelay: TimeInterval = PlayerChoice.takeoverDelay)
    public mutating func decide(_ candidates: [Candidate], elected: String?, now: Date) -> Decision
    public mutating func reset()
}
```

A player's id is its bundle identifier (`pid-<pid>` if it has none). Candidates arrive in MediaRemote's list order, which breaks remaining ties.

### 4.2 Helper

- `MediaRemoteBridge` resolves the symbols of §3 as **optional**. If any is missing, the helper keeps today's elected-only path unchanged (logged once at `.notice`).
- `NowPlayingMonitor.refresh()`: list clients → elected client's bundle id → each client's playback state (in parallel, joined on `queue`) → `PlayerChoice.decide` → info **with artwork** for the chosen client only → the existing `publish(info:isPlaying:bundleID:)`. `isPlaying` is the chosen client's own state (`== 1`), the counterpart of today's `…ApplicationIsPlaying`. The epoch guard covers every hop.
- The chosen `MRClient` is kept for commands: `send` and `seek` use `MRMediaRemoteSendCommandToClient` (seek = command 24 + `kMRMediaRemoteOptionPlaybackPosition`); with no chosen client, today's `MRMediaRemoteSendCommand` / `MRMediaRemoteSetElapsedTime`.
- A `recheckAt` schedules one extra refresh at that moment (its own work item, so a notification's debounce cannot cancel it).
- Artwork of a player that is not elected can be missing on the first request and present a moment later (spike: 0 B, then 188 KB on every later call). When the chosen player's info carries a title but no artwork bytes, the helper schedules **one** follow-up refresh 1 s later, once per track (keyed by bundle id + title + artist), so the cover does not wait for the next notification. Chrome items, which never have artwork, cost one extra refresh per item.
- The per-player notifications of §3 trigger refreshes too: `…PlayerIsPlayingDidChange` / `…PlayerPlaybackStateDidChange` immediately, `…PlayerNowPlayingInfoDidChange` and `…ApplicationDidUnregister` with the usual 150 ms debounce.
- When the published player changes, the play/pause flip bookkeeping (`lastIsPlaying`, `pauseObservedAt`, `resumeObservedAt`) is cleared first: a flip is a property of one player.
- A switch of the followed player is logged at `.notice` (persisted), e.g. `Following com.spotify.client (elected com.google.Chrome)`, so the next report like this one is readable from `log show`.

The app side, the XPC protocol and the snapshot format do not change.

## 5. Not in scope

Hardware media keys; several players inside one app (Chrome tabs share one client — the client's default player is used).

## 6. The blank title in both screenshots (`MarqueeText`)

A second, independent bug. The Chrome item's title (392.5 pt in a 240 pt slot) is long enough to scroll, and `MarqueeText.restart()` runs twice on appear — for `containerWidth`, then for `textWidth` — each time starting another `withAnimation(….repeatForever)`. SwiftUI animations are additive and a repeat-forever one never finishes, so the loops stack. Measured with an `Animatable` probe in an invisible window: the rendered offset ran from **+424.5** to −112 instead of 0 to −424.5, i.e. the title sat right of the slot for ~6 s, crawled back, and left again — both screenshots caught it away. Neither setting `offset = 0` without animation (what the code's comment claims cancels the loop) nor a `Transaction` with `disablesAnimations` cancels it (measured: the same +424.5).

Fix: the loop is a `keyframeAnimator(initialValue:repeating:)` that owns the offset (hold 1.2 s at 0, then linear to −distance at 30 pt/s, repeat), keyed with `.id` on the text and the distance, so a new title or width starts one fresh loop instead of layering another. Measured the same way: the offset stays within [−distance, 0] and a title change restarts at 0. Plan Task 3.
