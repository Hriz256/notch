# Notch — Sub-project 1: Island Core + Music

**Date:** 2026-09-11
**Status:** approved in conversation, awaiting written review
**Scope of this spec:** the reusable island shell (`IslandCore`) and the first feature that lives in it (`Music`). Other features (Coding Agent, Device Connections, Drop Zones, Voice/Translation) get their own specs and plug into the API defined here.

## 1. Goal

A personal macOS app that reproduces the look, feel and animations of Seam (getseam.app) for the built-in MacBook notch, starting with a now-playing island. It must feel native: one spring, morphing shape, no jumps, near-zero CPU when idle.

## 2. Constraints and decisions

| Topic | Decision |
|---|---|
| Platform | macOS 26 minimum, Apple Silicon, built-in display with notch only. External displays and notch-less Macs are out of scope. |
| Language / UI | Swift 6 (strict concurrency), SwiftUI for content, AppKit for the window. |
| Project shape | One Xcode project (`Notch.xcodeproj`) with an app target, an XPC helper target, and a local Swift Package `NotchKit` containing one module per concern. |
| Modules (this spec) | `IslandCore`, `MusicFeature`, `NowPlayingClient` (XPC client), helper target `NotchHelper` (XPC service). |
| Signing | Personal Apple ID development team in Xcode (stable code identity so TCC permissions survive rebuilds). Not sandboxed. |
| Name | App name **Notch**, bundle id `app.notch.Notch`, helper bundle id `com.apple.controlcenter.NotchHelper`. |
| Settings | No settings window in this sub-project. A status-bar menu with toggles backed by `UserDefaults`. |
| Distribution | None. Built and run locally from Xcode. |

## 3. Architecture

```
Notch.app
├── NotchApp (SwiftUI @main, LSUIElement, status-bar menu)
├── NotchKit (Swift Package)
│   ├── IslandCore        window, geometry, state machine, presentation queue, animation, feature API
│   ├── MusicFeature      now-playing feature: views + view model, uses NowPlayingClient
│   └── NowPlayingClient  XPC client protocol + AppleScript fallback + snapshot model
└── NotchHelper.xpc       XPC service, loads MediaRemote dynamically, publishes snapshots
```

Dependency direction: `NotchApp → MusicFeature → IslandCore`, `MusicFeature → NowPlayingClient`. `IslandCore` depends on nothing but AppKit/SwiftUI. Features never import each other.

### 3.1 IslandCore

**SurfaceWindow** — an `NSPanel` subclass: borderless, non-activating, `.nonactivatingPanel`, level above the menu bar (`NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)`), collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, transparent background, `hasShadow = false`, `ignoresMouseEvents` toggled by state (true when collapsed except for the notch rect itself, which needs hover tracking). It is never key or main.

**NotchGeometry** — computes the notch rect from `NSScreen.main`: `safeAreaInsets.top` gives notch height, `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` give the gap. Exposes `notchRect` (screen coordinates), `menuBarHeight`. Re-evaluated on `NSApplication.didChangeScreenParametersNotification`.

**IslandState** — enum:

```swift
enum IslandState: Equatable {
    case collapsed
    case peek(PresentationID)      // widened notch, compact content on the sides
    case expanded(PresentationID)  // panel grown downward
}
```

**Presentation** — what a feature asks the island to show:

```swift
struct Presentation: Identifiable {
    let id: PresentationID
    let featureID: FeatureID
    let priority: Priority           // .background < .activity < .alert
    let style: Style                 // .peek, .expanded
    let ttl: Duration?               // nil = sticky until dismissed by the feature
    let compact: AnyView             // left/right slots for .peek
    let expanded: AnyView?           // required when style == .expanded
}
```

**IslandPresenter** (`@MainActor @Observable`) — owns a queue of presentations and derives `IslandState`. Rules:

1. Highest priority wins. Same priority: newest wins.
2. A presentation with a `ttl` is removed when it expires (`DismissScheduler`), and the next in the queue becomes visible; if the queue is empty, the island collapses.
3. Hover/click on the collapsed island temporarily promotes the current `.background` presentation (e.g. music) to `.expanded`; mouse-out after 0.35 s demotes it back. Hover never overrides an `.alert`.
4. Features call `present(_:)`, `update(_:)`, `dismiss(_:)`. They never touch the window.

**Feature API**:

```swift
public protocol IslandFeature: AnyObject {
    var id: FeatureID { get }
    func activate(presenter: IslandPresenter) async   // start observing sources
    func deactivate()
}
```

Features are registered at app launch by `FeatureRegistry`; a `UserDefaults` bool per feature id enables/disables them (status-bar menu).

**SurfaceView** (SwiftUI root inside the window) — draws the black shape and hosts the active presentation. Shape: a rounded rect whose top edge is flush with the screen top and whose top corners *flare outward* (concave inverse corners) so it visually merges with the menu-bar notch. Bottom corner radius scales with height: collapsed 10 pt, peek 14 pt, expanded 24 pt.

**TransitionChoreographer** — one spring for geometry: `.spring(response: 0.42, dampingFraction: 0.78)`. Content transitions: `opacity + scale(0.94) + blur(6)` with `.animation(.easeOut(duration: 0.18).delay(0.06))` on appear, no delay on disappear. Honors `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` by switching to `.easeInOut(duration: 0.2)` with no blur.

**Sizes** (starting values, to be tuned against Seam side by side):

| State | Width | Height |
|---|---|---|
| collapsed | notch width | notch height |
| peek | notch width + 2 × 56 pt | notch height |
| expanded (music) | 390 pt | 200 pt |

Height/width are per-presentation: the expanded view reports its ideal size and the island animates to it.

### 3.2 NowPlayingClient

**NowPlayingSnapshot** — `Sendable` value:

```swift
struct NowPlayingSnapshot: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var artworkPNG: Data?          // nil if unchanged since last snapshot (see artworkID)
    var artworkID: String?
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var playbackRate: Double       // 0 = paused, 1 = playing
    var sourceBundleID: String?
    var timestamp: Date            // when elapsed was sampled
}
```

**NowPlayingSource** protocol with two implementations:

- `XPCNowPlayingSource` — connects to `NotchHelper.xpc`, receives snapshots via a delegate-style XPC protocol, sends commands (`play`, `pause`, `togglePlayPause`, `next`, `previous`, `seek(to:)`).
- `AppleScriptNowPlayingSource` — polls Spotify (`com.spotify.client`) and Music (`com.apple.Music`) every 2 s while either is running and frontmost-or-playing, using `NSAppleScript`/`OSAKit`. Artwork: Apple Music via AppleScript artwork data; Spotify via `artwork url` fetched over HTTP.

**NowPlayingCoordinator** — picks the source: tries XPC first; if the helper reports "MediaRemote unavailable" or no snapshot arrives within 5 s of a media app starting playback, falls back to AppleScript and logs the reason. Publishes an `AsyncStream<NowPlayingSnapshot>`.

**PlaybackProgressTracker** — pure function of `(snapshot, now) -> elapsed`: `elapsed + rate × (now − timestamp)`, clamped to `duration`. Drives a 1 Hz timer only while the expanded view is visible and `rate > 0`.

### 3.3 NotchHelper (XPC service)

- Target type: XPC Service embedded in the app, bundle id `com.apple.controlcenter.NotchHelper` (MediaRemote's client check on macOS 15.4+ allows bundle ids under `com.apple.controlcenter.`). This is the same technique Seam uses; it is a private-API workaround and may break in a future macOS, hence the AppleScript fallback.
- Loads `/System/Library/PrivateFrameworks/MediaRemote.framework` with `dlopen`, resolves `MRMediaRemoteRegisterForNowPlayingNotifications`, `MRMediaRemoteGetNowPlayingInfo`, `MRMediaRemoteGetNowPlayingApplicationIsPlaying`, `MRMediaRemoteGetNowPlayingClient` / `MRNowPlayingClientGetBundleIdentifier`, `MRMediaRemoteSendCommand`, `MRMediaRemoteSetElapsedTime` via `dlsym`. No private headers are checked in; function types are declared as `@convention(c)` typealiases.
- On each `kMRMediaRemoteNowPlayingInfoDidChangeNotification` / `...ApplicationIsPlayingDidChange` / `...ApplicationDidChange`, fetches info, builds a snapshot, dedups (skips if equal to the last sent one), debounces bursts to ≤ 4 per second, and sends artwork only when `artworkID` changed.
- Exposes an `NSXPCListener` with protocol `NowPlayingHelperProtocol` (commands in) and `NowPlayingHelperClientProtocol` (snapshots out).

### 3.4 MusicFeature

**MusicFeature: IslandFeature** — owns `NowPlayingCoordinator` and a `MusicViewModel`. Behavior:

- First snapshot with `title != nil` → `present` a sticky `.background` presentation with `style: .peek` (compact) — the island stays slightly widened while media exists.
- Track change (title/artist/artworkID changed while rate > 0) → `update` compact content and, in addition, raise a 2.5 s track-change banner showing the new title scrolling (Seam's "track change animation"). Toggle via `UserDefaults` key `music.trackChangePeek`. Implemented as a widening of the *same* presentation rather than a second `.activity` one — a second presentation gives the panel a new view identity and blinks it away and back, twice. For its duration the peek slots ask for 90 pt instead of 56 so the leading slot fits the title and artist beside the thumbnail; the island's own width animation is the entrance. 90 rather than the HUD's 96 because `IslandLayout.resolve` floors the *expanded* width at `notch + 2 × slot` as well, and 90 keeps the widened peek at exactly the 380 pt expanded card, so a skip while the user is hovering cannot resize the panel.
- Rate becomes 0 and stays 0 for 10 min → `dismiss` (island collapses to bare notch). Playback resumes → present again.
- Hover on collapsed/peek island → presenter promotes to `.expanded` (handled by IslandCore rule 3).
- Media app quits / no snapshot → dismiss.

**Views**:

- `MusicCompactView` — left slot: 18 pt artwork thumbnail with 4 pt radius, inset from the island's edge by the same 19 pt that centring gives it in the default 56 pt slot, and — for the track-change banner's 2.5 s — the new title (marquee) over its artist beside it; right slot: `VisualizerBars` (4 bars, animated with staggered `repeatForever` scale when playing, frozen at low height when paused).
- `MusicExpandedView` — layout per Seam screenshot: artwork 64 pt with 12 pt radius (left), `MarqueeText` title + secondary artist (center), `VisualizerBars` (right), `TimeProgressBar` (elapsed `m:ss` left, `-m:ss` remaining right, seekable by click/drag), transport row `backward.fill` / `play.fill`/`pause.fill` / `forward.fill` (SF Symbols, 22 pt). Top-right: `AudioOutputMenu` button listing CoreAudio output devices; selecting one sets the default output device. Background: black with a subtle radial tint from `DominantColorExtractor` (average color of artwork, 12 % opacity).
- Clicking the artwork opens the source app (`NSWorkspace.shared.open(urlForApplication(withBundleIdentifier:))`).

### 3.5 NotchApp

- `@main` SwiftUI `App` with `NSApplicationDelegateAdaptor`; `LSUIElement = true`.
- On launch: build `NotchGeometry`, create `SurfaceWindow`, register features (`MusicFeature`), activate enabled ones.
- Status-bar item (`MenuBarExtra`) with: per-feature toggles, "Reload helper", "Quit".
- Logging via `os.Logger(subsystem: "app.notch", category: <module>)`.

## 4. Data flow (music)

```
MediaRemote notif ─▶ NotchHelper ─(XPC)─▶ XPCNowPlayingSource ─▶ NowPlayingCoordinator
                                                                        │ AsyncStream<Snapshot>
                                                                        ▼
                                                                  MusicViewModel ─▶ IslandPresenter.present/update/dismiss
                                                                        │                       │
                                                        PlaybackProgressTracker           IslandState ─▶ SurfaceView (spring)
User taps ⏯ ─▶ MusicViewModel.command ─▶ NowPlayingCoordinator ─(XPC)─▶ NotchHelper ─▶ MRMediaRemoteSendCommand
```

## 5. Error handling

| Failure | Behavior |
|---|---|
| Helper fails to launch / MediaRemote symbols missing | Coordinator switches to AppleScript source; logs `.error` with reason. |
| No source produces data | Island stays collapsed; nothing is drawn. No "no media" UI. |
| Artwork missing or undecodable | Placeholder: `music.note` symbol on a dark gray rounded square. |
| XPC connection interrupted | Reconnect with exponential backoff (0.5 s → 8 s, max 5 tries), then fall back. |
| Screen parameters change (lid close, display sleep) | Recompute geometry; if no notch screen is available, hide the window until one returns. |
| Reduce Motion enabled | Cross-fade transitions, no spring overshoot. |

## 6. Testing

Unit tests (XCTest, `swift test` on `NotchKit`):

- `IslandPresenterTests` — priority ordering, TTL expiry, hover promotion/demotion, empty queue collapses, alert not overridden by hover.
- `PlaybackProgressTrackerTests` — playing advances, paused holds, seek resets, clamps at duration.
- `NowPlayingSnapshotDiffTests` — dedup and artwork-only-when-changed logic (helper-side policy extracted as a pure `SnapshotDedup` type shared via `NowPlayingClient`).
- `NotchGeometryTests` — rect computation from injected screen metrics.

Manual verification checklist (done by the user, guided): play Spotify → peek appears; hover → expands with correct artwork/progress; ⏯/⏭ work; track change peek; pause 10 min → collapses; kill helper → AppleScript fallback keeps working for Spotify.

## 7. Out of scope (this sub-project)

Settings window, external displays, swipe gestures, sounds, real audio-reactive visualizer, lyrics, browser-tab focusing, radio, Flow/focus timer, weather, calendar, battery, HUDs.

## 8. Idle-cost rules (from Seam's approach, adopted)

- When `IslandState == .collapsed` and no presentation is queued, stop every timer and repeating animation (visualizer, marquee, progress). Nothing may tick while the notch is bare.
- The helper flushes cached artwork on a `DispatchSource.makeMemoryPressureSource` warning.
- Target: ≤ 0.2 % CPU and ≤ 40 MB RSS while collapsed with music paused.

## 9. Reference

`research/seam-analysis.md` holds the reverse-engineering notes on Seam 1.14.7 (helper XPC protocol and policy names, settings keys, UI label vocabulary). It is a source of naming and behavior hints only; no code or assets are copied from Seam.

## 10. Open questions resolved

- Music source: any app via MediaRemote helper (not Spotify-only). Resolved by inspecting Seam's helper.
- Name: **Notch** (user did not object).
