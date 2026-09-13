# Notch — Sub-project 4: Volume & Brightness HUD

**Date:** 2026-09-13
**Status:** approved 2026-09-13 ("делаем, по стандарту")
**Reference:** Seam's "Brightness HUD" / "Volume HUD" (marketing screenshots the user sent on 2026-09-13: the collapsed island shows an icon and a label on the left — `sun` "Brightness", `speaker` "Sound" — and a thin white bar on the right; nothing else changes). Spike results (2026-09-13, macOS 26.5): `DisplayServicesGetBrightness` / `DisplayServicesRegisterForBrightnessChangeNotifications` resolve and work; on macOS 26 the volume and brightness banners are drawn by **Control Center**, not `OSDUIHelper` — `defaults write com.apple.controlcenter EnableSystemBanners -bool false` + restarting Control Center brings the old `OSDUIHelper` path back, and a `SIGSTOP`ped `OSDUIHelper` shows nothing. With both applied, the user confirmed that neither banner appears for volume or brightness keys.

## 1. Goal

When the volume or the built-in display's brightness changes — media keys, Control Center slider, AirPods stem, anything — the collapsed island shows the new level for a moment in place of the system HUD: icon and label on the left, a thin bar on the right. It is **display only**: no page in the stack, no expanded view, no control by scrolling or dragging. While the feature is on, the system's own HUD is suppressed so the two never appear together.

## 2. Decisions

| Topic | Decision |
|---|---|
| Feature id / title | `FeatureID("hud")`, title "HUD". Master switch = the registry's `feature.hud.enabled` (status-menu toggle "Volume & Brightness HUD"), on by default. |
| What is shown | A `Presentation` with `priority: .alert`, `style: .peek`, `expanded: nil`, `showsStackDots: false`, **`ttl: holdDuration`**. A `ttl` is what makes it an interruption in `IslandPresenter`'s terms (a transient that never joins the stack or the dots) rather than a card. Every reading is delivered with `present(_:)` under the same id — `present` on an existing id replaces it *and re-arms the TTL*, whereas `update` deliberately does not — so the presenter itself takes the HUD down 1.5 s after the last change. Leading slot = symbol + label; trailing slot = the bar. The island's standard 56 pt peek slots do not hold a label and a bar, so the presentation asks for **96 pt slots** (`Presentation.peekSlotWidth`, a small `IslandCore` addition: `IslandLayout.resolve` and `PeekRow` read it, default 56) and the peek island widens to `notch + 2 × 96`, growing out of the notch with the island's usual width animation, as Seam's does. Nothing else about the island changes; when the HUD ends the island returns to whatever card it was showing. |
| Copy and symbols | Brightness: `sun.max.fill`, label **"Brightness"**. Sound: label **"Sound"**; symbol `speaker.slash.fill` when muted or at 0, `speaker.wave.1.fill` below ⅓, `speaker.wave.2.fill` below ⅔, else `speaker.wave.3.fill`. Both 13 pt semibold white, symbol 12 pt, 6 pt apart, leading-aligned in the slot. The symbol sits in a fixed 14 pt box so the label does not shift as `speaker.wave.N` changes width. (Seam's exact copy; symbols chosen to match its glyphs.) |
| The bar | Trailing slot: a capsule **60 × 4 pt**, track white at 25 %, fill white, width = level. The fill animates `.easeOut(duration: 0.12)`; Reduce Motion drops the animation. Muted draws the fill at 0. |
| Timing | The presentation appears on the first change and is dismissed **1.5 s** after the *last* change (`holdDuration`); every further change of the same kind re-presents under the same id, which re-arms the TTL. The view model mirrors that lifetime with its own hold timer on the injected clock, so it knows when the HUD is gone and the next change presents afresh (a fresh id). A change of the *other* kind while one is up dismisses it and presents the new one at once (one HUD at a time, like the system). Appear and dismiss animations are the island's standard alert-peek animations. |
| Volume source | CoreAudio, no permissions: property listeners on the default output device for `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` and `kAudioDevicePropertyMute` (output scope, main element), plus `kAudioHardwarePropertyDefaultOutputDevice` on the system object to re-register when the device changes (no HUD on the device switch itself). A device without a settable main volume (HDMI, DisplayPort) is ignored — nothing is shown, as the system shows only a "no control" glyph there. The first reading after registration is stored silently; only *changes* present. |
| Brightness source | `DisplayServices.framework` (private), loaded with `dlopen`/`dlsym` at runtime: `DisplayServicesRegisterForBrightnessChangeNotifications(displayID, observer, callback)` — verified by spike on 2026-09-13: three arguments, the callback is a `CFNotificationCallback` whose `userInfo` carries `"value"`, and it fires on the registering thread's run loop — and `DisplayServicesGetBrightness(displayID, &value)` for the **built-in display** (`CGDisplayIsBuiltin`) only. If any symbol is missing, or the display cannot change brightness (`DisplayServicesCanChangeBrightness`), brightness is silently unavailable and logged once; the volume half keeps working. |
| Suppressing the system HUD | `SystemHUDSuppressor`, applied while the feature is active and at least one kind is on: 1) `EnableSystemBanners = false` in `com.apple.controlcenter` (via `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize`), 2) restart Control Center (`SIGTERM` to its process, found with `proc_listpids`/`proc_pidpath`; launchd brings it straight back), 3) `SIGKILL` the `OSDUIHelper` process and then `launchctl kickstart gui/<uid>/com.apple.OSDUIHelper` — **without** `-k`, which SIP refuses for both of these system agents (exit 150, "Operation not permitted while System Integrity Protection is engaged"), while signalling them ourselves is allowed because they run as the user — then `SIGSTOP` to the fresh `OSDUIHelper` process (found the same way, no `killall`). A **watchdog** every 5 s (only while applied) re-does step 3 if there is no `OSDUIHelper` process in the stopped state (`proc_pidinfo`, `pbi_status == SSTOP`). Lifted on deactivate, on the master switch going off, and in `applicationWillTerminate`: `OSDUIHelper` is kickstarted again (killed and relaunched, so the OSD requests that queued up while it was stopped die with it instead of replaying as a burst of stale bezels), the preference removed *only if we set it* (a user who already had it `false` keeps it), Control Center restarted. `hud.suppressionApplied` in `UserDefaults` records that we applied it, so a crash or `kill -9` is repaired at the next launch: if the flag is set and the feature is off, the suppressor lifts; if on, it re-applies. Restarting Control Center blinks the menu bar for a moment; a second flag, `hud.controlCenterConfigured` in `UserDefaults`, is what lets step 2 be skipped — written only once the restart has actually run and cleared on lift, because the preference being `false` proves nothing on its own (an earlier run could have written it and then failed to restart Control Center, leaving the old process drawing banners). |
| Known gaps (documented, accepted) | A media key at an already-maximal or minimal level changes nothing, so no HUD appears (the system would have shown one). While suppressed, `OSDUIHelper`'s other bezels (Caps Lock, keyboard backlight, eject) do not appear either. While a Code completion alert (a 4 s transient) is up, a HUD presented before it keeps losing the priority tie (the island's stack resolves equal priority by latest insertion) and stays invisible until the alert ends. A volume or brightness change while the user hovers an expanded card collapses that card for the HUD's 1.5 s and re-promotes it afterwards. |
| Settings | Keys `hud.volume` (true), `hud.brightness` (true). Surfaces: "HUD" submenu in the status menu with rows "Volume", "Brightness"; the island's context menu shows nothing for the HUD (it is never the current card). Both off = suppression lifted, monitors stopped. |
| Not in scope | Keyboard backlight, external displays, control by scroll or drag, an expanded page, custom copy, sounds. |

## 3. Architecture

```
NotchKit
├── HUDShared     pure, no AppKit/CoreAudio: HUDKind, HUDReading, HUDGlyph, HUDSession, SuppressionPlan
├── HUDFeature    VolumeMonitor, BrightnessMonitor, SystemHUDSuppressor, HUDSettings, HUDViewModel, views
IslandCore        Presentation.peekSlotWidth (default 56) honoured by IslandLayout.resolve and PeekRow
```

`HUDFeature: IslandFeature` registers as `FeatureID("hud")` after Drop Zones in `AppCoordinator`. It is not in `presenter.stackOrder` (it has no sticky card). It never imports another feature.

### 3.1 HUDShared

```swift
public enum HUDKind: String, Sendable, CaseIterable { case volume, brightness }

public struct HUDReading: Equatable, Sendable {
    public var kind: HUDKind
    public var level: Double        // clamped to 0...1
    public var isMuted: Bool        // volume only; false for brightness
    public init(kind: HUDKind, level: Double, isMuted: Bool = false)
}

public enum HUDGlyph {
    public static func symbol(for reading: HUDReading) -> String   // §2 "Copy and symbols"
    public static func label(for kind: HUDKind) -> String          // "Sound" / "Brightness"
    public static func barFraction(for reading: HUDReading) -> Double // 0 when muted, else level
}

/// The one-HUD-at-a-time state machine. Pure: the caller supplies the clock.
public struct HUDSession: Equatable, Sendable {
    public static let holdDuration: Duration = .milliseconds(1500)
    public enum Effect: Equatable, Sendable {
        case present(HUDReading)          // nothing was up
        case update(HUDReading)           // same kind was up
        case replace(HUDReading)          // other kind was up: dismiss it, present this
        case none                         // identical reading, or first silent reading
    }
    public private(set) var current: HUDReading?
    public mutating func receive(_ reading: HUDReading) -> Effect
    public mutating func expire() -> Bool          // true if something was up and is now gone
}

/// The steps a suppressor performs, as data, so the executor is the only impure part.
public enum SuppressionStep: Equatable, Sendable {
    case setBannersPreference(Bool?)   // false suppresses, nil removes the key
    case restartControlCenter          // SIGTERM; launchd brings Control Center back
    case kickstartOSDUIHelper          // SIGKILL, then launchctl kickstart gui/<uid>/com.apple.OSDUIHelper
    case stopOSDUIHelper               // SIGSTOP
}

public enum SuppressionPlan {
    public static func apply(preferenceAlreadyFalse: Bool) -> [SuppressionStep]
    public static func lift(weSetPreference: Bool) -> [SuppressionStep]
    public static func repairIfNeeded(osdHelperStopped: Bool) -> [SuppressionStep]   // watchdog
}
```

`HUDSession` rules: monitors deliver their first reading (and the reading after a device switch) through `baseline(_:)`, which records it and never presents. `receive(_:)` returns `.none` for a reading equal to the one already recorded or shown, `.present` when nothing is up, `.update` when the same kind is up, `.replace` when the other kind is up.

```swift
public mutating func baseline(_ reading: HUDReading)   // records without presenting
```

### 3.2 HUDFeature

- **`VolumeMonitor`** (`@MainActor`, `Observation`-free): owns the CoreAudio listeners described in §2 and calls `onReading(HUDReading, initial: Bool)` on the main actor. Handles default-device changes by re-registering and delivering the new device's level as `initial`. Exposes `start()` / `stop()`. All CoreAudio calls go through a `VolumeSource` protocol so tests use a fake.
- **`BrightnessMonitor`**: same shape over `DisplayServicesBridge` (the `dlopen`ed functions behind a protocol). Delivers `initial` on start, changes afterwards. Unavailable → `start()` logs once and delivers nothing.
- **`SystemHUDSuppressor`**: executes `SuppressionStep`s through a `SystemShell` protocol (`bannersPreference() -> Bool?`, `setBannersPreference(Bool?)`, `restartControlCenter()`, `kickstartOSDUIHelper()`, `stopOSDUIHelper()`, `isOSDUIHelperStopped() -> Bool`), off the main actor (the steps block for up to a second). `apply()` / `lift()` are `async`; the 5 s watchdog runs on an `IslandClock`. Persists `hud.suppressionApplied` and `hud.weSetBannersPreference` in `UserDefaults`. The real shell: `CFPreferences` for the preference; signals we send ourselves for both restarts (`SIGTERM` to Control Center, which launchd relaunches; `SIGKILL` to the helper followed by `launchctl kickstart gui/<uid>/com.apple.OSDUIHelper` via `Process`, without `-k` — SIP refuses `-k` for these agents with exit 150 — each waiting up to a second for the signalled pid to go); `kill(pid, SIGSTOP)` on the pid found with `proc_listpids` + `proc_pidpath` (retrying for up to a second after the kickstart, the helper takes a moment to appear); stopped-state check via `proc_pidinfo` (`PROC_PIDTBSDINFO`, `pbi_status == SSTOP`).
- **`HUDSettings`**: `hud.volume`, `hud.brightness` in `UserDefaults`; `isAnyKindOn`.
- **`HUDViewModel`** (`@MainActor @Observable`): folds monitors' readings through `HUDSession`, presents/updates/dismisses on the `IslandPresenting`, arms the hold timer on the injected `IslandClock`. `reading: HUDReading?` for the views. Stops cleanly on `teardown()`.
- **Views**: `HUDLeadingView` (symbol + label), `HUDBarView` (the capsule), built through a `HUDViewFactory` like the other features so the view model stays testable.
- **`HUDFeature`**: `activate` = settings → if any kind on: suppressor.apply, start monitors, build view model; `deactivate` = the reverse. `AppCoordinator` calls `hudFeature.prepareForTermination()` from `applicationWillTerminate`, and on launch the feature runs the crash repair described in §2 before anything else.

### 3.3 Data flow

```
media key / slider / AirPods
  → CoreAudio listener (VolumeMonitor)  or  DisplayServices callback (BrightnessMonitor)
  → HUDViewModel.receive(reading)  → HUDSession → .present/.update/.replace/.none
  → presenter.present / update / dismiss+present;  clock.schedule(holdDuration) → expire → dismiss
```

## 4. Error handling

- Missing DisplayServices symbols, a display that cannot change brightness, a device without volume control: the affected half is quietly unavailable; one `info` log line each.
- Suppression steps that fail (no Control Center process, `launchctl` non-zero exit): logged at `error`, the remaining steps still run, the watchdog retries the `OSDUIHelper` part every 5 s. The feature never refuses to show its own HUD because suppression failed — worst case both HUDs appear, which is the pre-feature state plus ours.
- The listeners are removed and the display callback unregistered in `stop()`; a callback that fires after `stop()` is dropped (`isStopped` guard, as in Drop Zones).

## 5. Testing

- `HUDSharedTests`: glyph thresholds (0, ⅓, ⅔, 1, muted), label copy, bar fraction; `HUDSession` transitions (baseline never presents, same reading is `.none`, update vs replace, expire); `SuppressionPlan` step lists for each case.
- `HUDFeatureTests`: `HUDViewModel` with a manual clock and a recording presenter (present → update re-arms → dismiss at 1.5 s; replace dismisses the old id first; teardown dismisses); `VolumeMonitor` / `BrightnessMonitor` with fakes (initial reading is a baseline, later ones present, device switch re-registers); `SystemHUDSuppressor` with a fake shell (apply order, lift only removes the preference it set, watchdog re-stops, crash repair on launch for both flag states); `HUDSettings` keys and defaults.
- Manual (the user): both HUDs appear and fade; the system banners do not; toggling the feature off restores them; quitting Notch restores them.
