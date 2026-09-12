# Notch — Sub-project 3: Drop Zones

**Date:** 2026-09-12
**Status:** approved (user waived per-section review: "не спрашивай ок или нет. Мне нужен результат как в оригинале")
**Reference:** Seam 1.14.7 "Drop Zones". Research: `research/drop-zones-mechanics.md` (binary analysis: trigger, catcher window, stash storage, drag-out, thumbnails, exact constants), `research/drop-zones-macos.md` (API notes + spike results: a private-space window neither receives nor blocks drops; global mouse monitors work without Accessibility), `research/drop-zones-visual.md` + `research/reference/drop-zones/*.jpg` (user's phone video of Seam: zones, drop, stash peek, hover, drag-out).

## 1. Goal

While the user drags files anywhere on the Mac and brings them near the notch, the island opens into drop zones — **AirDrop** and **File Stash** (optionally a third **Add to Stash** / **Replace Stash** zone). Dropping on AirDrop opens the system AirDrop sheet; dropping on the stash keeps copies of the files for 24 hours, shown in the island as a thumbnail stack with a count badge, from where they can be dragged back out into any app. Look, timings and behaviour follow Seam; the only deliberate additions are a "Clear stash" menu row and a "Reveal in Finder" row (Seam has neither; both are cheap and obviously useful).

## 2. Decisions

| Topic | Decision |
|---|---|
| Feature id / title | `FeatureID("dropzones")`, card title "Drop Zones". Master switch = the registry's `feature.dropzones.enabled` (status-menu toggle, label "Drop Zones"). |
| Drag detection | Seam's mechanism: four global `NSEvent` monitors (`.leftMouseDown`, `.leftMouseDragged`, `.leftMouseUp`, `.flagsChanged`) + `NSPasteboard(name: .drag).changeCount` snapshotted on mouse-down. A drag is "content dragging" once the change count differs from the snapshot **and** the pasteboard carries files (file URLs, file promises, image data, or Chrome's `org.chromium.chromium-initiated-drag`). Because the pasteboard may be filled a few events late, the check repeats on every dragged event until it succeeds or the mouse goes up. No CGEvent tap, no timers, no Accessibility. |
| Hot rect | `CGRect(x: screen.midX − 150, y: screen.maxY − 120, width: 300, height: 220)` clipped to the screen (Seam's exact numbers): zones open when the dragged cursor enters it, close 0.3 s after it leaves. A modifier key pressed mid-drag closes the zones for that drag. |
| Drop catcher | A separate ordinary-space `DropCatcherWindow` (borderless `.nonactivatingPanel`, `alphaValue 0`, `isOpaque false`, clear background, no shadow, level `statusWindow + 2` = one above the island, `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`, `canBecomeKey/Main false`, `constrainFrameRect` overridden to the identity so AppKit cannot push a frame that reaches the screen's top edge back down onto the visible area). Frame = the zones panel's screen rect grown 20 pt on the left, right and bottom — never above the top, which is the screen's own. It is ordered in (and `ignoresMouseEvents = false`) only while the zones are shown; otherwise ordered out. Registered types: `NSFilePromiseReceiver.readableDraggedTypes` + `.fileURL`, `.URL`, `.png`, `.tiff`. It is **invisible and only receives the drop**: the spike proved the private-space island neither receives nor blocks drops, so the island keeps drawing the zones and this window takes the drag messages at alpha 0. |
| The drag image: the mirror window | The island's private SkyLight Space (absolute level 400) composites above the system's drag-image window, so the thumbnail in the user's hand would be hidden *behind* the zones panel. Fixed by a **mirror window**: `SurfaceController` keeps a second `SurfaceWindow` with the same frame, level and collection behaviour that is never adopted into the private Space (`ignoresMouseEvents`, `alphaValue 0`, ordered in at build time). `IslandPresenting.setSurfaceMirrored(_:)` — a no-op by default, implemented by `IslandPresenter` — trades the two: the mirror gets a `PassThroughHostingView<SurfaceView>` over the same presenter and alpha 1, the primary drops to alpha 0 (`MirrorSwap`). Both render the same state, so the swap is pixel-identical while the island is static. `DragDetector` therefore emits `.began` on promotion (before `.enteredHotRect`, which is why `receive` returns `[Output]`) and `DropZonesViewModel` mirrors *there* — at drag start, anywhere on screen — so the mirror has laid out the island's current shape before the panel is presented into it; swapped later, SwiftUI coalesces the first render with the expansion and the panel pops instead of growing. Released `mirrorRelease` = 500 ms after the panel comes down (`.ended`/`.cancelled` with no panel up release at once; `stop()` releases). The presenter calls back synchronously rather than being observed, for the same reason `onCatcherFrameChange` does. Rejected alternatives: moving the island window itself into the active user Space (`SLSGetActiveSpace` + `SLSSpaceAddWindowsAndRemoveFromSpaces`) changed nothing on macOS 26.5; drawing the panel from a separate ordinary-Space window made it read as a shape of its own rather than one growing out of the notch. |
| Reading the drop | 1) file URLs (`NSPasteboardURLReadingFileURLsOnly`); else 2) `NSFilePromiseReceiver`s received into `<tmp>/app.notch/DragStaging/<UUID>/` with a 5 s wait; else 3) raw PNG/TIFF data written as `Image.png` into the same staging folder. Nothing → drop ignored. |
| Zones | `ZoneState(airdrop: Bool, stash: Bool, secondZone: Bool, stashDropAction: .replace/.add)` → 1–3 `Zone`s: `.airDrop`, `.stash`, `.addToStash`/`.replaceStash` (the action *opposite* to the default appears as the third zone when `secondZone` is on and the stash is non-empty; with an empty stash the third zone is not shown). During a drag that started from our own stash only `.stash` is shown (drop = no-op). |
| Widths | Panel 280×140 pt, cards inset 14, gap 8. Two cards: 50/50, targeted 65/35. Three cards: 1/3 each, targeted 45 % / 27.5 % / 27.5 %. Targeted card scale 1.02. |
| Drop on stash | Add (default) or replace per `stashDropAction`; the third zone does the other action. Files are **copied** into `~/Library/Application Support/Notch/Stash/<UUID>/<name>` (original untouched); the index `~/Library/Application Support/Notch/stash.json` holds `[StashedFile]` + `stashedAt`. TTL **86 400 s** from `stashedAt`, checked on load and armed as a one-shot timer while running; expiry clears files and index. |
| Drop on AirDrop | Zones dismiss at once; after 0.3 s `NSSharingService(named: .sendViaAirDrop)` → `canPerform(withItems:)` → `perform(withItems:)`. No picker, no anchoring; failure is logged only. The stash is untouched. |
| Settle | After a stash drop the panel shows a single full-width stash card headed "N File(s)" with the thumbnails entering (0.4 s), then the zones presentation is dismissed (island collapses) and the stash peek shows. |
| Stash card | `.background` peek, sticky: leading = thumbnail stack, trailing = count circle. Hover-expanded: **380 × 124** — 380 pt wide like the Music and Code cards, because the user wants every page the same width. The same two slots on top (a real `PeekRow`, so they hug the island's edges and slide outward as it grows), then a **row of the stashed files** as individual 40×40 tiles, then a caption row `tray.fill` + "N file(s) · <size>". |
| Stash row (**departs from Seam**, at the user's request) | Seam's expanded card shows the same fanned stack as the peek; pulling one particular file out of a pile of overlapping tiles is guesswork, so the expanded card lays the files out in one row instead — newest leftmost (`index.files` reversed), 40 pt tiles 8 pt apart, centred, 8 pt below the peek row. Hovering a tile lifts it 6 pt and scales it 1.06 (`.spring(response: 0.25, dampingFraction: 0.7)`); Reduce Motion drops both and dims the unhovered tiles to 0.85 instead. At most **seven boxes**: seven tiles, or six and a "+N" chip (same 40×40 box, 12 pt semibold blue on `Palette.cardFill`, not draggable, not a target). Seven is what the card's 380 pt holds — 7 × 40 + 6 × 8 = 328, leaving the 26 pt side margins the peek slots' centres sit on; an eighth would run into the island's rounded corners. No scrolling. The compact fan in the peek is unchanged. |
| Drag out | The thumbnail stack (peek and expanded) is an `NSDraggingSource`: one `NSFilePromiseProvider` per stashed file (delegate copies the stashed file to the destination), all files in one session, drag image = cascade of 32×32 `NSWorkspace` icons offset (+4, −4) per item, `sourceOperationMask` = `.copy` outside the app / `[.copy, .generic, .move]` inside. A session that ends with a non-empty operation **clears the stash** with a poof (Seam's observed behaviour: after dragging out, the island moved on to the next card); a cancelled session leaves it. |
| Drag out, one file | Each tile in the expanded row is its own drag source for its own file (one promise, that file's icon as the drag image). Both kinds of drag-out mark `dragOutPhase = .dragging`, so the panel offers the stash card alone either way; `dragOutEnded(completed:files:)` takes a `DragOutScope` (`.all` — the default, and the only one that empties the stash — or `.single(UUID)`). A completed `.single` poofs that tile alone (fade + scale over 0.25 s) and then removes just that file: `StashStore.remove(fileID:)` deletes its folder and rewrites the index, the rest of the pile keeps its card, its id and its `stashedAt`. The last file leaving dismisses the stash presentation exactly as a completed whole-stash drag-out does. Each tile's context menu also carries a "Remove `<name>`" row through the same path. |
| Settings | Keys `dropzones.airdrop` (true), `dropzones.stash` (true), `dropzones.secondZone` (false), `dropzones.stashDropAction` ("replace" \| "add", default **"add"** — Seam defaults to Replace, but a stash that silently drops the file already in it is the one behaviour nobody expects; Replace stays a menu row away, and the third card away). Surfaces: the island's context menu (Cards section + the rows below) and a "Drop Zones" submenu in the status menu. Rows: "AirDrop zone", "File Stash zone", "Offer the other action as a third zone", "When stash has files: Replace / Add" (checkmarked pair), "Reveal stash in Finder", "Clear stash". |
| Not in scope | Menu-bar stash item, external displays (single notch screen, like the rest of Notch), a settings window, onboarding. |

## 3. Architecture

```
NotchKit
├── DropZonesShared    pure, no AppKit: DragDetector, ZoneLayout, StashIndex, ByteFormatting, DragOutPolicy
├── DropZonesFeature   DragObserver, DropCatcherWindow, DropPayloadReader, StashStore, ThumbnailProvider,
│                      AirDropSender, StashDragSource, DropZonesSettings, DropZonesViewModel, views
IslandCore             PeekRow becomes public (the stash expanded view reuses it)
```

`DropZonesFeature: IslandFeature` registers as `FeatureID("dropzones")`. It never imports `MusicFeature` or `CodeAgentFeature`.

### 3.1 DropZonesShared

```swift
public enum Zone: String, CaseIterable, Sendable, Codable { case airDrop, stash, addToStash, replaceStash }
public enum StashDropAction: String, Sendable, Codable { case replace, add }

public struct ZoneState: Equatable, Sendable {
    public var airdrop: Bool, stash: Bool, secondZone: Bool
    public var stashDropAction: StashDropAction
    public var stashHasFiles: Bool
    public var isDragOut: Bool
    public func zones() -> [Zone]        // see §2 "Zones"; empty if nothing enabled
}

public struct ZoneLayout: Equatable, Sendable {
    public static let panelSize = CGSize(width: 280, height: 140)
    public static let inset: CGFloat = 14, gap: CGFloat = 8, targetedScale: CGFloat = 1.02
    /// The cards start below the notch's own glass rather than under it: the panel's top
    /// 34 pt are the island's black shape, not a target.
    public static let topInset: CGFloat = 34
    /// The area the cards are laid out in: `panelSize` inset by `topInset` at the top and
    /// `inset` on the other three sides.
    public static var contentRect: CGRect { get }
    public static func contentRect(for size: CGSize) -> CGRect
    public struct Slot: Equatable, Sendable { public var zone: Zone; public var frame: CGRect; public var isTargeted: Bool }
    public var slots: [Slot]
    public static func resolve(zones: [Zone], targeted: Zone?, size: CGSize = panelSize) -> ZoneLayout
    /// Which zone contains `point` (panel coordinates, origin top-left); nil in the gaps/margins.
    public func hitTest(_ point: CGPoint) -> Zone?
}

/// Pure drag state machine fed by DragObserver. Events carry only what AppKit gave us.
public struct DragDetector: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, mouseDown, dragging(inHotRect: Bool), cancelled }
    public enum Event: Equatable, Sendable {
        case mouseDown(changeCount: Int)
        case dragged(changeCount: Int, hasFiles: Bool, location: CGPoint)
        case flagsChanged
        case mouseUp
    }
    /// No `.none`: an event that changed nothing returns `[]`. Promotion over the notch is
    /// two pieces of news in one event (`.began` then `.enteredHotRect`), which is why the
    /// result is a list — the island mirrors itself on the first and opens the zones on the
    /// second, and a cursor that promotes inside the rect and stops sends no further event.
    public enum Output: Equatable, Sendable { case began, enteredHotRect, leftHotRect, ended, cancelled }
    public private(set) var phase: Phase
    public init(hotRect: CGRect)
    public mutating func receive(_ event: Event) -> [Output]
}

public struct StashedFile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID; public var name: String; public var storedPath: String; public var bytes: Int64; public var originalPath: String?
}
public struct StashIndex: Codable, Equatable, Sendable {
    public static let ttl: TimeInterval = 86_400
    public var files: [StashedFile]; public var stashedAt: Date?
    public var totalBytes: Int64
    public func isExpired(now: Date) -> Bool
    public mutating func apply(_ action: StashDropAction, adding: [StashedFile], now: Date)   // replace resets stashedAt; add keeps it if present
    public mutating func removeAll()
}

public enum ByteFormatting { public static func fileSize(_ bytes: Int64) -> String }   // "89 KB", "1.2 MB" (ByteCountFormatter .file)
public enum StashCaption { public static func text(count: Int, bytes: Int64) -> String } // "1 file · 89 KB", "3 files · 1.2 MB"
public enum ZoneTitle { public static func label(_ zone: Zone, fileCount: Int) -> String } // "AirDrop", "File Stash"/"1 File"/"3 Files", "Add to Stash", "Replace Stash"

public enum DragOutPolicy {
    public static func operationMask(insideApplication: Bool) -> NSDragOperation   // via UInt rawValue in Shared to stay AppKit-free: returns UInt
    public static func dragImageOffset(index: Int) -> CGPoint                       // (4·i, −4·i)
}
```

### 3.2 DropZonesFeature

- **`DragObserver`** (`@MainActor`): installs the four global monitors, owns a `DragDetector`, reads `NSPasteboard(name: .drag)` change count on mouse-down and file-ness on dragged events (cheap `types` check: contains `fileURL`, promise types, `png`/`tiff`, or the Chrome type). Emits `began` / `enteredHotRect` / `leftHotRect` / `ended` / `cancelled` to the view model. A drag that started from our own stash is known from the view model's own `dragOutPhase`, not from the observer.
- **`DropCatcherWindow` / `DropCatcherView`**: as in §2. The view implements `draggingEntered/Updated/Exited/performDragOperation`, converts the cursor to panel coordinates (panel frame passed in), and forwards `targeted(zone:)` / `exited` / `dropped(info)` to a delegate. `draggingUpdated` returns `.copy` over a zone, `[]` elsewhere.
- **`DropPayloadReader`**: reads file URLs / promises / image data from an `NSDraggingInfo` into `[URL]` (async; staging dir `<tmp>/app.notch/DragStaging/<UUID>/`, 5 s promise timeout).
- **`StashStore`** (actor): base dir injectable; `load() -> StashIndex` (drops missing files, purges expired), `stash(_ urls: [URL], action:) -> StashIndex` (copy into `Stash/<UUID>/<name>`, write index atomically), `remove(fileID:)` (deletes one file's folder and its index entry, leaving the rest of the pile and its `stashedAt` alone), `clear()`, `reveal()` (opens the Stash dir in Finder — main-actor helper), `promiseWrite(file:to:)` used by the drag-out delegate.
- **`ThumbnailProvider`** (actor): `QLThumbnailGenerationRequest(fileAt:size: 2×requested square, scale: backingScaleFactor ?? 2, representationTypes: .thumbnail)` via `QLThumbnailGenerator.shared`; in-memory cache keyed by path+size; fallback `NSWorkspace.shared.icon(forFile:)`; result `Thumbnail(image: NSImage, hasPreview: Bool)`.
- **`AirDropSender`**: `send(_ urls: [URL])` → `canPerform` → `perform`; logs failures.
- **`StashDragSource`**: `NSViewRepresentable` wrapping an `NSView` drag source; `mouseDragged` starts `beginDraggingSession` with `StashFilePromiseProvider`s (subclass of `NSFilePromiseProvider`, delegate `StashFilePromiseDelegate` writing on a background `OperationQueue`), cascade drag image, operation mask per `DragOutPolicy`; on `endedAt:operation:` reports `.completed` / `.cancelled` to the view model. Marks `DragObserver.isDragOutActive` for the session's lifetime.
- **`DropZonesSettings`** (`@MainActor @Observable`, UserDefaults-backed like `CodeSettings`).
- **`DropZonesViewModel`** (`@MainActor @Observable`): owns the phases and the two presentations:
  - **Zones presentation** (id fixed per showing): `priority .alert`, `style .expanded`, `expandedSize 280×140`, `showsStackDots: false`, `expanded = ZonesView` — the island itself draws the panel, so it grows out of the notch shape that is already on screen. Presented on `enteredHotRect` (if any zone is enabled), updated in place on targeting changes, dismissed on `leftHotRect` (after 0.3 s), `ended` without drop, `cancelled`, AirDrop drop (immediately), stash drop (after the 0.4 s settle). `showZones()` hands the catcher's frame to the feature *before* presenting, in the same turn the drag event arrives (see `onCatcherFrameChange`), so the window that receives the drop is never a turn behind the cards. On mouse-up a 500 ms drop grace holds the panel and the catcher up until AppKit has delivered the drop; a `showingID` (fresh per showing) is what stops a stale settle or grace tearing down a later drag's panel.
  - **Stash presentation** (id kept while files exist): `priority .background`, `style .peek`, `expandedSize CGSize(width: 380, height: 124)` (the width every other page uses), leading `ThumbnailStack(compact)`, trailing `FileCountCircle`, expanded `StashExpandedView`. Presented when the stash becomes non-empty, updated on changes (a single file leaving keeps the id: the row closes up rather than the card blinking), dismissed on clear/expiry/poof — including the poof of the last single file.
  - Phases: `StashPhase { idle, hovering, targeted(Zone), dropped(pending: [URL]), settling, stashed }`, `DragOutPhase { idle, dragging, completed, cancelled }` (only a whole-stash drag-out reaches `completed`), `DragOutScope { all, single(UUID) }`, plus `poofingFileIDs` for the tiles fading out one at a time.
  - Timings via `IslandClock`: leave-debounce 0.3 s, settle 0.4 s, AirDrop delay 0.3 s, poof 0.25 s then dismiss, TTL one-shot.
- **Views** (`Views/`): `ZonesView` (panel, `ZoneCardView` per slot, animated by an `Equatable` `AnimationState { zones, targeted, hasPending, isDragOut }`), `ZoneCardView` (dashed card, icon, label, optional mini stack when the stash has files), `AirDropGlyph` (hand-drawn: centre dot r 2.2 + three ring arcs at radii 5.5/9/12.5, stroke 1.5, 70° gap at the bottom), `ThumbnailCard`, `ThumbnailStack` (tokens: compact `thumbSize 22, rotations [−9, 0, 9], scales [1, 0.94, 0.88], cornerRadius 4`; large `thumbSize 48, rotations [−10, 0, 10], scales [1, 0.94, 0.88], cornerRadius 6`; top three files, newest on top), `FileCountCircle` (18 pt, 1.5 pt blue ring, count 10 pt semibold blue), `StashExpandedView` (public `PeekRow` on top + `StashThumbnailRow` + caption row, with `StashRowLayout` owning the row's arithmetic and `StashOverflowChip` the "+N" box), `DropZonesContextMenu`.

### 3.3 Visual spec (from `research/drop-zones-visual.md`)

- Panel: island expanded 280×140, bottom radius 24 (existing layout). Cards: `RoundedRectangle(cornerRadius: 12)` stroked with `Color(nsColor: .systemBlue)` 1.5 pt, dash `[4, 4]`; fill blue 6 % (targeted 12 %); targeted scale 1.02; when some card is targeted the others fade to 60 %. Icon 26 pt centred, label 12 pt semibold blue 8 pt below. AirDrop card uses `AirDropGlyph`; stash `tray.and.arrow.down.fill`; add `plus.rectangle.on.rectangle`; replace `arrow.triangle.2.circlepath`.
- Stash card with files (and the settle card): header row `tray.and.arrow.down.fill` 13 pt + "N File(s)" 13 pt semibold blue at the top, large `ThumbnailStack` centred below.
- Peek: thumbnail stack in the leading slot, count circle in the trailing slot (both centred in their 56 pt slots — verify with render tests like `CompactLayoutRenderTests`).
- Hover-expanded (380 × 124): top row is a real `PeekRow` at the card's width, so the two slots stay hugging the island's edges and slide outward with it; 8 pt below it the row of 40 pt tiles (`cornerRadius` 6, 8 pt apart, centred, newest leftmost, hover lift 6 pt / scale 1.06, at most seven boxes with a "+N" chip as the seventh past seven files); caption row centred 24 pt below the tiles' bottom edge (14 pt gap + a 20 pt row): `tray.fill` 11 pt blue + caption 12 pt medium white 70 %.
- Per-file poof: the same shape as the whole-card one (scale → 0.6 + opacity → 0 over 0.25 s), played on the single tile whose file has been taken.
- Animations: geometry via the existing `TransitionChoreographer`; targeting/width changes `.spring(response: 0.3, dampingFraction: 0.8)`; cards appear `.opacity + .scale(0.95)` on `contentIn`; dropped thumbnails enter with scale 1.12 → 1 over 0.3 s; poof = scale → 0.6 + opacity → 0 over 0.25 s. Reduce Motion: no scale/rotation animations, opacity only.

## 4. Error handling

- Copy failure for a file → that file is skipped and logged (`app.notch`, `dropzones.store`); an all-failed drop leaves the stash unchanged and dismisses the zones normally.
- Index unreadable → treated as empty and rewritten. Missing stored files at load → pruned.
- Promise wait > 5 s → whatever has arrived is used; nothing → drop ignored.
- AirDrop `canPerform == false` → logged, nothing shown (Seam parity).
- QuickLook failure → icon fallback (`hasPreview false` changes only card chrome).
- Drag-out promise write failure → logged; the receiving app shows its own error; the stash is not cleared.
- Screen without a notch / geometry unavailable → the observer stays installed but the hot rect is empty (zones never open).

## 5. Idle cost

Eight monitors — the four masks registered globally *and* locally, because a drag that starts inside one of our own windows is delivered only to the local one — whose handlers do at most an `Int` comparison until a mouse-down occurs. A `.leftMouseDragged` is dropped before the cursor or the pasteboard is read unless the detector is in `mouseDown` or `dragging`; in `mouseDown` it costs one `changeCount` read and one `types` check per event until content is confirmed, and after promotion one `NSEvent.mouseLocation` read and a rect check. No timers while idle (the TTL one-shot exists only while files are stashed). Thumbnails are generated once per stashed file and cached in memory (≤ a few files).

Two windows exist from activation and cost nothing at `alphaValue 0`: the **catcher**, ordered in once and thereafter only moved and toggled between opaque and transparent to the mouse (a window that joins the list mid-drag can be skipped by AppKit's destination resolution — the one unexplained dropped-drop), and the island's **mirror**, an empty ordinary-Space twin of the surface window ordered in at build time so the system's drag image composites above the zones panel (§2, "The drag image").

## 6. Testing

- `DropZonesSharedTests`: `DragDetector` (mouse-down snapshot, late pasteboard fill, enter/leave outputs, flagsChanged cancels, mouseUp ends), `ZoneLayout` (zone sets for every `ZoneState` combination incl. drag-out and empty stash, fractions 50/50, 65/35, 1/3, 45/27.5, insets/gaps, `hitTest` in gaps → nil), `StashIndex` (replace vs add, TTL boundary, totalBytes, codable round-trip), `ByteFormatting`/`StashCaption`/`ZoneTitle`, `DragOutPolicy`.
- `DropZonesFeatureTests`: `StashStore` on a temp dir (copy, index, clear, prune missing, expired purge), `DropCatcherWindow` configuration (level, behaviour, alpha, registered types), `DropZonesViewModel` with a fake presenter and manual clock (open on enter, leave debounce, targeting updates in place, stash drop → settle → dismiss + peek presented, AirDrop drop → dismissed + sender called after 0.3 s, drag-out completed → poof → dismissed, cancelled → kept, expiry), `DropZonesSettings`, render tests for peek slot centring and the expanded top row alignment.

## 7. Delivery

Branch `feature/drop-zones`; plan `docs/superpowers/plans/2026-09-12-drop-zones.md`; Opus implementers/reviewers; user verifies against the reference frames with real drags; Seam stays installed for comparison until sub-project 5.
