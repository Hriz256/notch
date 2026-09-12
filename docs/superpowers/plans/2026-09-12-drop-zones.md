# Drop Zones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seam-style drop zones in the notch: drag files near the notch → AirDrop / File Stash (/ Add or Replace) zone cards; stash keeps copies for 24 h, shows a thumbnail stack + count in the island, drags back out into any app.

**Architecture:** Two new NotchKit modules — `DropZonesShared` (pure: drag state machine, zone layout, stash index, formatting, drag-out policy) and `DropZonesFeature` (global drag observer, invisible drop-catcher window in the ordinary space, payload reader, stash store, thumbnails, AirDrop, drag-out source, settings, view model, views). `IslandCore` only makes `PeekRow` public.

**Tech Stack:** Swift 6.3 (Xcode 26.6), SwiftUI + AppKit, QuickLookThumbnailing, Swift Testing, XcodeGen, `xcodebuild`, `swift test`. Spec: `docs/superpowers/specs/2026-09-12-drop-zones-design.md`. Research: `research/drop-zones-mechanics.md`, `research/drop-zones-macos.md` (+ spike `spikes/DropSpike`), `research/drop-zones-visual.md` with frames in `research/reference/drop-zones/`.

## Global Constraints

- macOS 26.0 deployment target; Swift language mode 6, strict concurrency complete; no `@unchecked Sendable` without a one-line justification; no `print` in shipped code; logging via `os.Logger(subsystem: "app.notch", category: "dropzones.*")`.
- Feature id `FeatureID("dropzones")`, title "Drop Zones". Settings keys exactly: `dropzones.airdrop`, `dropzones.stash`, `dropzones.secondZone`, `dropzones.stashDropAction` (values `replace` | `add`, default `add`).
- Exact numbers: hot rect `CGRect(x: midX − 150, y: maxY − 120, w: 300, h: 220)` clipped to the screen; panel 280×140, inset 14, gap 8; widths 50/50, targeted 65/35; three zones 1/3, targeted 45/27.5/27.5; targeted scale 1.02; leave debounce 0.3 s; settle 0.4 s; AirDrop delay 0.3 s; poof 0.25 s; TTL 86 400 s; promise wait 5 s; drag image 32×32 icons offset (4·i, −4·i); operation mask `.copy` outside / `[.copy, .generic, .move]` inside.
- Files are copied to `~/Library/Application Support/Notch/Stash/<UUID>/<name>`; index at `~/Library/Application Support/Notch/stash.json`; staging `<NSTemporaryDirectory()>/app.notch/DragStaging/<UUID>/`. Originals are never moved or deleted.
- The drop catcher is an ordinary-space window (never added to the private SkyLight space), invisible (`alphaValue 0`) and only there to receive the drop; the island keeps drawing the zones. The catcher is ordered in **once**, at activation, and from then on only moved and toggled between opaque and transparent to the mouse (`ignoresMouseEvents`); it leaves the window list only when the feature is switched off. AppKit resolves a drag's destination from the windows that were already there as the pointer moved, so a window ordered in mid-drag can be skipped altogether.
- Verification per task: `cd NotchKit && swift test 2>&1 | tail -5` green and pristine; `xcodegen generate >/dev/null && xcodebuild -project Notch.xcodeproj -scheme Notch -configuration Debug -derivedDataPath build build 2>&1 | grep -E "error|warning: |BUILD" | head` → `** BUILD SUCCEEDED **`. Commit each task; messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Work on branch `feature/drop-zones`.
- Agents must not perform real drags (they cannot) and must not touch `~/Library/Application Support/Notch/` — tests use temporary directories. Do not launch the app from tests.

---

## File Structure

```
NotchKit/Sources/DropZonesShared/
  Zone.swift              Zone, StashDropAction, ZoneState (+ zones())
  ZoneLayout.swift        panel constants, Slot, resolve, hitTest
  DragDetector.swift      pure state machine
  StashIndex.swift        StashedFile, StashIndex (TTL, apply, totalBytes)
  Formatting.swift        ByteFormatting, StashCaption, ZoneTitle
  DragOutPolicy.swift     operation masks (UInt), drag image offsets
NotchKit/Sources/DropZonesFeature/
  DropZonesFeature.swift             IslandFeature wiring
  Settings/DropZonesSettings.swift
  Drag/DragObserver.swift            global monitors + DragDetector + pasteboard classification
  Drag/DropCatcherWindow.swift       window + DropCatcherView (NSDraggingDestination)
  Drag/DropPayloadReader.swift       URLs / promises / image data → [URL]
  Drag/StashDragSource.swift         NSViewRepresentable drag source + StashFilePromiseProvider/Delegate
  Stash/StashStore.swift             actor
  Stash/ThumbnailProvider.swift      actor + Thumbnail
  Share/AirDropSender.swift
  DropZonesViewModel.swift
  Views/ZonesView.swift, ZoneCardView.swift, AirDropGlyph.swift, ThumbnailCard.swift, ThumbnailStack.swift,
        FileCountCircle.swift, StashCompactViews.swift, StashExpandedView.swift, DropZonesContextMenu.swift, Palette.swift
NotchKit/Sources/IslandCore/Surface/SurfaceView.swift   PeekRow → public (own file Surface/PeekRow.swift)
App/AppCoordinator.swift, App/StatusMenu.swift          registration + "Drop Zones" submenu
Tests: NotchKit/Tests/DropZonesSharedTests/*, NotchKit/Tests/DropZonesFeatureTests/*
```

---

### Task 1: Modules, models, formatting, drag-out policy, public PeekRow (TDD)

**Files:** `NotchKit/Package.swift` (+ targets `DropZonesShared`, `DropZonesFeature` (deps IslandCore, DropZonesShared), test targets `DropZonesSharedTests`, `DropZonesFeatureTests`), `DropZonesShared/{Zone,StashIndex,Formatting,DragOutPolicy}.swift`, `DropZonesFeature/DropZonesFeature.swift` (placeholder feature with `id` only), `IslandCore/Surface/PeekRow.swift` (moved out of `SurfaceView.swift`, `public struct PeekRow` with `public init(leading: AnyView, trailing: AnyView, notch: CGSize)`), tests `DropZonesSharedTests/{ZoneStateTests,StashIndexTests,FormattingTests,DragOutPolicyTests}.swift`.

**Interfaces (spec §3.1):** `Zone`, `StashDropAction`, `ZoneState.zones()`; `StashedFile`, `StashIndex` (`ttl`, `totalBytes`, `isExpired(now:)`, `apply(_:adding:now:)`, `removeAll()`); `ByteFormatting.fileSize`, `StashCaption.text(count:bytes:)`, `ZoneTitle.label(_:fileCount:)`; `DragOutPolicy.operationMask(insideApplication:) -> UInt` (1 outside, 21 inside) and `dragImageOffset(index:)`.

- [ ] Tests: `zones()` for all combinations — both on + empty stash → `[.airDrop, .stash]`; secondZone on + empty stash → still two; secondZone on + files + action replace → `[.airDrop, .stash, .addToStash]`; action add → third `.replaceStash`; airdrop off → `[.stash]`; isDragOut → `[.stash]` regardless; nothing enabled → `[]`. StashIndex: replace resets `stashedAt` and files; add appends and keeps `stashedAt`; add on empty sets it; expired exactly at ttl; totalBytes sums. Formatting: `fileSize(89_000)` contains "KB"; caption "1 file · " / "3 files · "; ZoneTitle "File Stash" for 0, "1 File", "3 Files", other zones fixed. DragOutPolicy masks 1 / 21, offsets (8, −8) for index 2.
- [ ] Implement; `swift test`; move `PeekRow` to its own file as public (no behaviour change; existing IslandCore render tests stay green); commit `feat(DropZones): modules, models, formatting and public PeekRow`.

### Task 2: DragDetector (TDD)

**Files:** `DropZonesShared/DragDetector.swift`, `DropZonesSharedTests/DragDetectorTests.swift`.

**Interface:** spec §3.1 `DragDetector(hotRect:)`, `receive(_:) -> Output`. Rules: `.mouseDown(changeCount:)` snapshots and enters `.mouseDown`; `.dragged(changeCount:hasFiles:location:)` while `.mouseDown` promotes to `.dragging` only if `changeCount != snapshot && hasFiles` (otherwise stays `.mouseDown` — later dragged events re-check); while `.dragging`, entering/leaving the hot rect emits `.enteredHotRect` / `.leftHotRect` once per crossing; `.flagsChanged` while `.dragging` → `.cancelled` (phase `.cancelled`; further dragged events ignored until mouse-up); `.mouseUp` → `.ended` if dragging (or cancelled → `.none`), back to `.idle`. Events in `.idle` other than mouse-down are ignored.

- [ ] Tests: late pasteboard fill (first dragged has same count → none; second with new count + files → still `.none` until inside rect); enter emits once, leave emits once, re-enter emits again; mouse-up inside rect → `.ended`; flagsChanged → `.cancelled` then mouse-up → `.none`; dragged without files never promotes; mouse-down twice re-snapshots.
- [ ] Implement; commit `feat(DropZonesShared): drag state machine`.

### Task 3: ZoneLayout (TDD)

**Files:** `DropZonesShared/ZoneLayout.swift`, `DropZonesSharedTests/ZoneLayoutTests.swift`.

**Interface:** spec §3.1. Panel 280×140, inset 14 → content rect (14, 14, 252, 112); gap 8. Two zones: widths (252−8)/2 each; targeted: 65 % / 35 % of 244. Three: (252−16)/3 each; targeted 45 % / 27.5 % / 27.5 % of 236. Single zone: full content rect. Slot frames are in panel coordinates (origin top-left); `isTargeted` set on the targeted slot only; `hitTest` returns the slot whose frame contains the point.

- [ ] Tests: frames for 1/2/3 zones untargeted (exact numbers), targeted first/second/third, hitTest inside each card, in the gap → nil, outside panel → nil, empty zones → no slots.
- [ ] Implement; commit `feat(DropZonesShared): zone layout and hit testing`.

### Task 4: StashStore and ThumbnailProvider

**Files:** `DropZonesFeature/Stash/StashStore.swift`, `Stash/ThumbnailProvider.swift`, `DropZonesFeatureTests/StashStoreTests.swift`, `ThumbnailProviderTests.swift`.

**Interfaces:** `actor StashStore { init(baseDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }); func load() -> StashIndex; func stash(_ urls: [URL], action: StashDropAction) -> StashIndex; func clear(); var stashDirectory: URL; func write(file: StashedFile, to destination: URL) throws }` — `stash` copies each URL into `Stash/<UUID>/<lastPathComponent>` (FileManager.copyItem; on failure skip + log), builds `StashedFile` (bytes from attributes), applies the action to the loaded index (replace deletes the previous stored folders), writes `stash.json` atomically (`Data.write(options: .atomic)`). `load()` decodes, prunes entries whose `storedPath` is missing, and if `isExpired` clears everything. `clear()` removes `Stash/` and the index. `actor ThumbnailProvider { init(size: CGFloat); func thumbnail(for url: URL) async -> Thumbnail }` per spec §3.2 (`Thumbnail { image: NSImage; hasPreview: Bool }`, `NSImage` is not Sendable → wrap in a `@unchecked Sendable` struct with the justification "immutable after creation").

- [ ] Tests on a temp base dir: stash two files → both copied, originals intact, index has 2 + `stashedAt`; replace → old folders gone; add → 3 files, `stashedAt` unchanged; load prunes a deleted stored file; load after `now` + 25 h → empty and directory removed; clear removes everything; unreadable index → empty. ThumbnailProvider: PNG written to temp → `hasPreview == true` and image size > 0; a `.notarealtype` file → falls back with `hasPreview == false`; second call for the same URL hits the cache (count generator calls through an injectable generator closure).
- [ ] Implement; commit `feat(DropZonesFeature): stash store and thumbnail provider`.

### Task 5: DragObserver, DropCatcherWindow, DropPayloadReader, AirDropSender

**Files:** `DropZonesFeature/Drag/DragObserver.swift`, `Drag/DropCatcherWindow.swift`, `Drag/DropPayloadReader.swift`, `Share/AirDropSender.swift`, tests `DropZonesFeatureTests/{DragPasteboardClassifierTests,DropCatcherWindowTests}.swift`.

**Interfaces:**
- `enum DragPasteboardClassifier { static func hasFileContent(types: [NSPasteboard.PasteboardType]) -> Bool }` — true for `.fileURL`, any of `NSFilePromiseReceiver.readableDraggedTypes`, `.png`, `.tiff`, or `org.chromium.chromium-initiated-drag`.
- `@MainActor final class DragObserver { init(hotRect: @escaping () -> CGRect, pasteboard: NSPasteboard = NSPasteboard(name: .drag)); var onEvent: ((DragDetector.Output) -> Void)?; var isDragOutActive: Bool; func start(); func stop() }` — four global monitors per spec; handlers feed `DragDetector` with `NSEvent.mouseLocation`; on `enteredHotRect` also report the location.
- `@MainActor final class DropCatcherWindow: NSPanel` configured per spec §2; `func show(frame: CGRect)` (setFrame + `ignoresMouseEvents = false` + `orderFrontRegardless`), `func hide()`; `final class DropCatcherView: NSView, NSDraggingDestination` with `weak var delegate: DropCatcherDelegate` (`@MainActor protocol DropCatcherDelegate: AnyObject { func catcher(_:, targetedAt point: CGPoint) ; func catcherExited(_:) ; func catcher(_:, dropped info: any NSDraggingInfo) -> Bool }`); `draggingUpdated` returns `.copy` when the delegate reports a zone under the point (delegate returns `Zone?`), else `[]`. Point is converted to panel coordinates (origin top-left) using `panelFrame: CGRect` set by the owner.
- `enum DropPayloadReader { @MainActor static func fileURLs(from info: any NSDraggingInfo, stagingRoot: URL, timeout: TimeInterval = 5) async -> [URL] }` per spec §2.
- `enum AirDropSender { @MainActor static func send(_ urls: [URL]) -> Bool }`.

- [ ] Tests: classifier for each type family and Chrome; DropCatcherWindow config (styleMask contains `.nonactivatingPanel`, `alphaValue == 0`, `level == statusWindow + 2`, collectionBehavior contains the four options, `canBecomeKey == false`, registered types include `.fileURL` and the promise types); `show(frame:)` makes `isVisible` true and `ignoresMouseEvents` false, `hide()` reverses.
- [ ] Implement; commit `feat(DropZonesFeature): drag observer, drop catcher window, payload reader, AirDrop`.

### Task 6: DropZonesSettings and DropZonesViewModel (TDD)

**Files:** `DropZonesFeature/Settings/DropZonesSettings.swift`, `DropZonesViewModel.swift`, tests `DropZonesSettingsTests.swift`, `DropZonesViewModelTests.swift`.

**Interfaces:** `@MainActor @Observable final class DropZonesSettings { init(defaults: UserDefaults = .standard); var airdrop, stash, secondZone: Bool; var stashDropAction: StashDropAction }` (keys per Global Constraints, defaults true/true/false/replace, write-through). `@MainActor @Observable public final class DropZonesViewModel { static let featureID = FeatureID("dropzones"), displayTitle = "Drop Zones", zonesSize = CGSize(280,140), stashExpandedSize = CGSize(width: 0, height: 76); init(presenter: any IslandPresenting, clock: any IslandClock, settings: DropZonesSettings, store: StashStore, thumbnails: ThumbnailProvider, airDrop: @escaping ([URL]) -> Bool, viewFactory: DropZonesViewFactory, now: ...); var index: StashIndex; var phase: StashPhase; var dragOutPhase: DragOutPhase; var targeted: Zone?; var zones: [Zone]; var layout: ZoneLayout; func handle(_ output: DragDetector.Output); func targeted(at point: CGPoint) -> Zone?; func catcherExited(); func drop(urls: [URL]) async; func dragOutEnded(completed: Bool); func loadStash() async; func clearStash() async; func revealStash(); settings toggles… ; var islandPresenter: any IslandPresenting; var catcherFrameNeeded: CGRect? (nil when zones hidden) }` and `DropZonesViewFactory(zones:, stashLeading:, stashTrailing:, stashExpanded:)` like `CodeViewFactory` with a `.placeholder`. Presentation rules per spec §3.2.

- [ ] Tests (FakePresenter + ManualClock as in `CodeAgentViewModelTests`): enter → zones presentation `.alert/.expanded` 280×140; leave → dismissed after 0.3 s (not before); re-enter within 0.3 s cancels the dismiss; ended → dismissed at once; `targeted(at:)` updates in place (same id) and returns the zone; drop on `.stash` → `store.stash` called with replace, phase `.settling`, dismissed after 0.4 s, stash presentation presented (`.background/.peek`, expandedSize width 0 height 76); drop on `.addToStash` → action add; drop on `.airDrop` → dismissed immediately, airDrop closure called after 0.3 s with the URLs, stash untouched; isDragOut zones = `[.stash]` and drop → no-op; `dragOutEnded(completed: true)` → dragOutPhase `.completed`, stash cleared after 0.25 s and presentation dismissed; `completed: false` → nothing; expiry timer at ttl clears; nothing enabled → enter presents nothing; `catcherFrameNeeded` non-nil only while zones shown.
- [ ] Implement; commit `feat(DropZonesFeature): settings and view model`.

### Task 7: Views, drag-out source, context menu (render tests)

**Files:** `DropZonesFeature/Views/*.swift`, `Drag/StashDragSource.swift`, tests `DropZonesFeatureTests/{DropZonesViewsTests,StashLayoutRenderTests}.swift`.

Visual spec = design §3.3 (match `research/reference/drop-zones/*.jpg`). Details:
- `Palette`: `static let blue = Color(nsColor: .systemBlue)`, card fill blue 0.06 / 0.12, label white 0.7.
- `AirDropGlyph: View` (Canvas): dot r 2.2 filled; arcs radii 5.5 / 9 / 12.5 stroke 1.5 round caps spanning 125° → 415° (70° gap centred at the bottom); sized by `.frame`.
- `ZoneCardView(slot: ZoneLayout.Slot, fileCount: Int, files: [StashedFile], thumbnails:)`: dashed `RoundedRectangle(12)` stroke `[4,4]` 1.5 pt, fill, icon 26 pt, label 12 pt semibold, scale 1.02 when targeted, opacity 0.6 when another card is targeted; for `.stash` with files: header row (13 pt icon + "N Files") + large `ThumbnailStack`.
- `ZonesView(model:)`: `ZStack` positioning each card at `slot.frame` (`.position` on the centre, `.frame(slot.size)`), `.animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.animationState)` where `AnimationState: Equatable { zones, targeted, hasPending, isDragOut }`; settle state shows one full-width stash card.
- `ThumbnailCard(thumbnail:, size:, cornerRadius:)`: image `.aspectRatio(.fit)` in a square box, rounded, 1 px white 18 % stroke, black background.
- `ThumbnailStack(files:, tokens:, thumbnails:)` with `ThumbnailStackTokens.compact` / `.large` per spec; newest on top; rotation in degrees; Reduce Motion → no animated rotation.
- `FileCountCircle(count:)` 18 pt.
- Stash compact views: leading = `StashDragSource { ThumbnailStack(compact) }`, trailing = `FileCountCircle`; `StashExpandedView`: `PeekRow(leading:trailing:notch:)` (notch size from a `@Environment(\.notchSize)` value that `SurfaceView` sets — add `NotchSizeKey` in IslandCore, default 185×32) on top, caption row 26 pt below the notch.
- `StashDragSource: NSViewRepresentable` (files, `onEnded: (Bool) -> Void`, `observer: DragObserver`): `mouseDown` records, `mouseDragged` past 4 pt begins the session per spec §2 (promise providers, cascade image from `NSWorkspace.shared.icon(forFile:)` 32×32, mask via `DragOutPolicy`), `endedAt` → `onEnded(operation != [])`; `acceptsFirstMouse` true.
- `DropZonesContextMenu` (ViewModifier on all stash content and the zones panel): `CardsMenuSection`, then checkmarked rows "AirDrop zone", "File Stash zone", "Offer the other action as a third zone", section "When stash has files" with "Replace" / "Add" checkmarks, `Divider`, "Reveal stash in Finder", "Clear stash" (disabled when empty).

- [ ] Render tests (ImageRenderer, as in `CompactLayoutRenderTests`): the compact thumbnail stack is centred in the leading slot and the count circle in the trailing slot; `ZonesView` with two zones renders two non-overlapping dark-blue regions whose widths follow 50/50 and 65/35 (sample pixel columns); `AirDropGlyph` renders non-empty. View tests: `ZoneTitle` shown on cards, caption text.
- [ ] Implement; commit `feat(DropZonesFeature): zone and stash views, drag-out source, context menu`.

### Task 8: Feature wiring, app registration, status menu

**Files:** `DropZonesFeature/DropZonesFeature.swift` (real), `App/AppCoordinator.swift`, `App/StatusMenu.swift`, `project.yml` if the QuickLookThumbnailing framework needs listing.

- [ ] `DropZonesFeature.activate`: build settings, `StashStore(baseDirectory: ~/Library/Application Support/Notch)`, `ThumbnailProvider(size: 48)`, view model (+ `Task { await model.loadStash() }`), `DragObserver` (hot rect from `ScreenMetrics.current()` → `NotchGeometry`), `DropCatcherWindow` shown/hidden by observing `model.catcherFrameNeeded` (use `withObservationTracking` loop or a `didSet` callback on the model), catcher delegate → model. `deactivate` stops the observer, hides the catcher, dismisses presentations (stash files stay on disk).
- [ ] Register in `AppCoordinator.start()` after Code. Status menu: "Drop Zones" submenu with the same rows as the context menu (Toggles bound to settings; "Clear stash"/"Reveal").
- [ ] Build (`xcodebuild`), `swift test`; commit `feat(DropZones): feature wiring and app menu`.

### Task 9: Runtime verification and polish

- [ ] Build, launch; user drags a file toward the notch: zones open at the hot rect, cards highlight, drop into stash → settle → peek with thumbnail and "1"; hover → caption; drag out to Finder → copy lands, stash clears; AirDrop drop → system sheet appears. `log show --last 5m --info --debug --predicate 'subsystem == "app.notch" AND category BEGINSWITH "dropzones"'` shows the sequence.
- [ ] Idle audit: `ps -o %cpu,rss -p $(pgrep -x Notch)` with no drag ≈ 0 % CPU; note in `docs/superpowers/notes/2026-09-12-dropzones-idle-cost.md`.
- [ ] Fix visual mismatches the user reports against `research/reference/drop-zones/`; commit `chore: drop zones runtime verification notes`.

## Self-review notes
Spec §2 rows → Tasks: drag detection/hot rect → 2, 5; catcher → 5; reading the drop → 5; zones/widths → 1, 3, 7; drop on stash/AirDrop/settle → 4, 6; stash card/hover → 6, 7; drag out → 7; settings → 6, 7, 8. §4 errors → 4, 5, 6. §5 idle → 5, 9. §6 tests → 1–7. Type names checked: `DragDetector.Output`, `ZoneLayout.Slot`, `StashIndex`, `StashedFile`, `DropZonesViewFactory`, `DropCatcherDelegate`, `ThumbnailStackTokens` used consistently.
