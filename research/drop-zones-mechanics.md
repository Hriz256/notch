# Seam Drop Zones — mechanics, numbers and behaviour

Target: reproduce Seam 1.14.x "Drop Zones" (AirDrop / file stash) in the `notch` clone.
Source of facts: static analysis of `/Applications/Seam.app/Contents/MacOS/Seam` (arm64, fully
stripped of Swift function symbols, but Swift reflection metadata + ObjC class metadata + the
`__objc_stubs` selector table are intact), the earlier extracts in `research/`, and
`getseam.app`. **No code or assets were copied.**

Method notes (so results can be reproduced):
- Swift stored-property names/types came from `__swift5_fieldmd` + `__swift5_reflstr`, with
  symbolic references resolved through nominal type descriptors.
- ObjC call sites were recovered from `__objc_stubs` (each stub is `adrp/ldr selref; br _objc_msgSend`),
  giving `bl 0x…` → selector-name mapping; `objdump --macho -d` provides the instruction stream.
- Method IMP addresses came from `__objc_classlist` → class rw data → method list.
- Cited addresses below are load addresses in that binary (base `0x100000000`).

Everything marked *(inference)* is a reading of the disassembly, not a literal string.

---

## 0. Type inventory (from Swift reflection metadata)

Files (from `research/swift-files.txt`): `DragObserver.swift`, `DraggableStashView.swift`,
`DropCatcherWindow.swift`, `DropzonesManager.swift`, `DropzonesPane.swift`,
`DropzonesSplitView.swift`, `DropzonesThumbnailView.swift`, `DropzonesView.swift`,
`FileStackView.swift`, `StackedThumbnails.swift`, `StashDragItemProvider.swift`,
`StashStorage.swift`, `ThumbnailManager.swift`, `SegmentedPicker.swift`, `WindowDragBlocker.swift`.

Exact stored properties (field metadata, declaration order):

```
class  DragObserver
    state: DragObserver.DragState          // enum: inactive, active, targeted, dropped
    isMonitoring: Bool
    dragSessionSignpost: OSSignpostID?
    mouseDownMonitor: Any?
    mouseDraggedMonitor: Any?
    mouseUpMonitor: Any?
    flagsChangedMonitor: Any?
    dragPasteboard: NSPasteboard
    pasteboardChangeCountOnMouseDown: Int
    isMouseDown: Bool
    isContentDragging: Bool
    lastMouseLogTime: Double
    lastDragEventTime: Double
    targetedFiles: [URL]
    isDragOutActive: Bool
    flagsCancellationTask: Task<(), Never>?
    pendingDropTask: Task<(), Never>?
    cachedZoneState: DropzonesConfig.ZoneState?
    dropCatchers: [DropCatcherWindow]

struct DragGeometry            { screenFrame: CGRect }
struct DropzonesConfig.ZoneState { airdrop: Bool; stash: Bool; hasSecondStashZone: Bool;
                                   stashDropAction: StashDropAction }
enum   StashDropAction         { replace, add }                 // raw strings: "replace", "addToStash"
struct DropzonesData           { stashedFiles: [URL]; pendingFiles: [URL]; phase: StashPhase;
                                 targetedZone: TargetedZone?; dragOutPhase: DragOutPhase;
                                 isSecondZoneDrop: Bool }
enum   StashPhase              { idle, hovering, hoverExpanded, stashed }
enum   TargetedZone            { airdrop, fileStash, addToStash, replaceStash }
enum   DragOutPhase            { idle, lifted, dragging, completed, cancelled }
class  DropzonesManager        { stashSettleTask, airDropTask, dragOutTask: Task<(),Never>?;
                                 draggedOutFiles: [URL] }
struct DropzonesPane           { _enabled, _airdropEnabled, _fileStashEnabled,
                                 _secondStashZoneEnabled: AppStorage<Bool>;
                                 _stashDropAction: AppStorage<String> }
struct DropzonesView           { data: DropzonesData; _metrics; _surfaceColors }
struct DropzonesExpandedView   { data: DropzonesData; _metrics }
struct DropzonesSplitView      { phase, targetedZone, stashedFiles, hasPendingFiles,
                                 isSecondZoneDrop, dragOutPhase, _surfaceColors }
struct DropzonesSplitView.AnimationState
                               { phase, targetedZone, hasPendingFiles,
                                 threeZone: Bool, hideAirDrop: Bool, isSecondZoneDrop: Bool }
struct ZoneCard                { iconSource: ZoneCardIconSource; label: String; color: Color;
                                 isTargeted: Bool; files: [URL]; phase: StashPhase;
                                 actionPreview: String?; canShowFiles: Bool;
                                 isCompactZone: Bool; dragOutPhase: DragOutPhase; _metrics }
enum   ZoneCardIconSource      { system(String), asset(String) }       // multi-payload enum
struct DropzonesPeekRow        { files: [URL]; _totalBytes; _surfaceColors }
struct FileCountCircle         { count: Int; _metrics; _surfaceColors }
struct DropzonesThumbnailView  { files: [URL]; dragOutPhase: DragOutPhase; _metrics }
struct FileThumbnailView       { url; size; thumbnailManager }
class  FileStackPresenter      { _fileStackFiles: [URL]?; _fileStackMode: FileStackMode?;
                                 _$observationRegistrar }
enum   FileStackMode           { dragging(position:), entering(centerPosition:, stash…),
                                 poofing(position:), stashed }
struct UnifiedFileStackView    { files: [URL]; mode: FileStackMode }
struct FileStackView           { files: [URL]; isFullyExpanded: Bool; dragOutPhase: DragOutPhase?;
                                 thumbnailSize: CGFloat; rotationOverflow: CGFloat }
struct StackedThumbnails       { files: [URL]; tokens: ThumbnailStackTokens;
                                 rotationSpread: Double; thumbnailManager }
struct ThumbnailStackTokens    { thumbSize: CGFloat; rotations: [Double]; scales: [CGFloat];
                                 depthOffsets: [CGFloat]?; cornerRadius: CGFloat;
                                 compact: Bool; alwaysPreviewStyle: Bool }
struct ThumbnailCardStyle      { hasPreview: Bool; cornerRadius: CGFloat; compact: Bool }
class  StashStorage            { ttl: Double }
class  StashDragItemProvider : NSFilePromiseProvider
                               { fileURL: URL; promiseDelegate: StashFilePromiseDelegate }
class  StashFilePromiseDelegate{ sourceURL: URL }
struct DraggableStashView      { files: [URL]; content: Content }     // NSViewRepresentable
class  DragSourceView : NSView { files: [URL]; hostingView: NSHostingView<…>? }
class  DragSourceMonitor       { views: NSHashTable<DragSourceView>; monitor: Any? }
class  DropCatcherWindow : NSWindow   (no stored properties)
class  DropCatcherView : NSView       { dragDelegate: (any …)?; isTargetedProvider: () -> Bool }
class  PromiseCollector        { condition: NSCondition; urls: [URL]; settled: Int }
struct StashMenuItem           { presenter: FileStackPresenter }
enum   FeatureComponent        { …, dragObserver, … }
```

---

## 1. Trigger — how a system-wide drag is detected

**Mechanism: four global `NSEvent` monitors + the drag pasteboard's `changeCount`. No CGEvent tap,
no polling timer.** (`CGEventTapCreate` *is* imported but only for the voice/keystroke feature.)

`DragObserver` installs exactly four monitors via
`addGlobalMonitorForEventsMatchingMask:handler:` (`0x10049be40`), with these masks:

| Call site | mask | `NSEvent.EventTypeMask` |
|---|---|---|
| `0x100149b5c` | `0x2` | `.leftMouseDown` |
| `0x10014a43c` | `0x40` | `.leftMouseDragged` |
| `0x10014a504` | `0x4` | `.leftMouseUp` |
| `0x10014a5cc` | `0x1000` | `.flagsChanged` |

`DragObserver.init` (`0x10014991c`) does `NSPasteboard(name: …)` (`pasteboardWithName:` at
`0x100149970`). The name constant is the GOT bind
`__DATA_CONST __got 0x1005A5E08 bind AppKit/_NSPasteboardNameDrag` — i.e. **`NSPasteboard(name: .drag)`**.
It initialises `pasteboardChangeCountOnMouseDown = -1` (`mov x8, #-0x1` at `0x10014997c`).

Detection flow *(inference from the field set + two `changeCount` sends)*:
1. `leftMouseDown` → `isMouseDown = true`, snapshot `dragPasteboard.changeCount`.
2. `leftMouseDragged` → if `dragPasteboard.changeCount != pasteboardChangeCountOnMouseDown`,
   a real drag with pasteboard content is in flight → `isContentDragging = true`.
3. `leftMouseUp` → reset.
4. `flagsChanged` → `flagsCancellationTask` — pressing a modifier mid-drag cancels the zones
   *(inference; the field name is literal)*.

**Chrome special case (unchanged from the earlier notes):** the string
`org.chromium.chromium-initiated-drag` at `0x1005681b0` is referenced from `0x100150f6c`.
Chrome puts only this private type on the drag pasteboard at drag start, so without an explicit
check Chrome drags look empty.

### Proximity — zones appear only near the notch, not at drag start

Hard numbers, decoded from `0x10014ab10`–`0x10014ab64`:

```
let hot = CGRect(x: screenFrame.midX - 150,
                 y: screenFrame.maxY - 120,
                 width: 300,
                 height: 220)
if hot.contains(mouseLocation) && mouseLocation.y <= screenFrame.maxY { … show zones … }
```

(doubles: `0xC062C00000000000` = −150.0, `0xC05E000000000000` = −120.0,
`0x4072C00000000000` = 300.0, `0x406B800000000000` = 220.0; `CGRectContainsPoint` at `0x10014ab64`,
then `CGRectGetMaxY` compared against the cursor Y at `0x10014ab80`.)

So the effective hot zone is **300 pt wide × 120 pt tall, horizontally centred, hugging the top
edge of the screen** (the rect nominally extends 100 pt above the screen; the `maxY` guard clips it).
Zones do **not** appear the moment a drag starts — the cursor must enter this rect.

Once inside, the drag pasteboard is read (`0x10014ac48`, see §2) and only if it yields ≥1 file URL
does the state advance (`DragState`: `inactive → active → targeted → dropped`).

Throttling: `fmov d2, #0.5; fcmp` at `0x10014af38` against `now - lastMouseLogTime` — a 0.5 s
os_log throttle, not a behavioural threshold.

os_log: subsystem `app.seam`, categories `DragSession` (`0x10014bd84`) and `DropCatcher`
(built inline at `0x100151af8`).

---

## 2. Windows — `DropCatcherWindow`

**Separate from the island/Surface window. One catcher window per screen** (`dropCatchers: [DropCatcherWindow]`).

### Configuration (fully decoded, `0x100151b30`–`0x100151ce8`)

```
super.init(contentRect: .zero,
           styleMask:  0x80,   // .nonactivatingPanel
           backing:    2,      // .buffered
           defer:      false)
isOpaque          = false
backgroundColor   = NSColor.clear
hasShadow         = false
level             = (<surface window level> ?? (.statusBar + 1)) + 1      // see below
collectionBehavior = 0x151
canBecomeVisibleWithoutLogin = true
hidesOnDeactivate = false
ignoresMouseEvents = true
alphaValue        = 0.0
contentView       = DropCatcherView()
```

- `level`: the main path reads a level off another object and adds 1 (`adds x2, x21, #1` at
  `0x100151c78`); the nil fallback path builds `NSWindowLevel(rawValue: 25) + 1` (= `.statusBar + 1`,
  constants `0x19` and `0x1` at `0x100151d28`) and then also adds 1. So the catcher sits **one level
  above the Surface window**, and `.statusBar + 2 = 27` when there is no Surface window *(inference on
  which object supplies the base level)*.
- `collectionBehavior = 0x151` = `[.canJoinAllSpaces (0x1), .stationary (0x10), .ignoresCycle (0x40),
  .fullScreenAuxiliary (0x100)]`.
- **`alphaValue = 0`** — the catcher is completely invisible. All zone visuals are drawn by the
  island/Surface window; this window exists purely as an `NSDraggingDestination`. AppKit still routes
  drag messages to a zero-alpha, `ignoresMouseEvents` window.
- `DropCatcherWindow` also overrides `canBecomeKeyWindow` and `canBecomeMainWindow` (IMPs
  `0x100151e48`, `0x100151e50`; both return `false` — `mov w0, #0` at `0x100151ee8`).

### No private SkyLight space

**There is no SkyLight/CGS usage anywhere in the binary** — `nm -u` shows no `SLSSpaceAddWindowsAndRemoveFromSpaces`,
no `CGSAddWindowsToSpaces`, and SkyLight is not linked. All-spaces behaviour comes purely from
`collectionBehavior`.

### Show/hide and frame

Loop at `0x10014c440`–`0x10014c4f8` reconciles `dropCatchers` against an array of
`DragGeometry.screenFrame` values:

- for each active screen: `setIgnoresMouseEvents(false)`, `setFrame(screenFrame, display: false)`,
  `orderFront(nil)`
- for surplus windows: `setIgnoresMouseEvents(true)`, `orderOut(nil)`

So each catcher covers a **whole screen's frame** (not just the notch rect); the narrow hot zone
of §1 is what gates showing it. This is what fixed "Files dropped on an external display's drop zone
now land in the stash" (changelog 1.10.2).

### Registered dragged types

`DropCatcherView.init(frame:)` (IMP `0x100152168`) calls `registerForDraggedTypes:` at `0x100152134`
with an array built at `0x100151984`:

```
var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
types += [ … ]          // appended via a generic array-append helper
```

The AppKit pasteboard-type constants bound in this binary are:
`NSPasteboardTypeFileURL`, `NSPasteboardTypePNG`, `NSPasteboardTypeString`, `NSPasteboardTypeTIFF`,
`NSPasteboardTypeURL`, plus `NSPasteboardURLReadingFileURLsOnlyKey`
(GOT `0x1005A5E10`…`0x1005A5E38`). No `NSFilenamesPboardType`.

### `NSDraggingDestination` methods implemented (from the class method list)

`draggingEntered:` `0x100152428` · `draggingUpdated:` `0x10015250c` · `draggingExited:` `0x100152618` ·
`prepareForDragOperation:` `0x1001526ec` · `performDragOperation:` `0x1001529bc`.
All hop to the main actor first (`swift_task_isCurrentExecutor` preamble) and forward to a
`dragDelegate`. There is **no** `concludeDragOperation:` and no `wantsPeriodicDraggingUpdates`.

### `WindowDragBlocker`

Separate small helper: `WindowDragBlocker.NonDraggableView` overrides `mouseDownCanMoveWindow`
(IMP `0x100431224`) — used to stop AppKit's background-drag from moving the island window.

---

## 3. Zone cards

### Zone set (1–3 zones)

`DropzonesConfig.ZoneState = (airdrop: Bool, stash: Bool, hasSecondStashZone: Bool,
stashDropAction: StashDropAction)`. The mangled tuple label string
`7airdrop_AA12primaryStashAA06secondC0t` (offset 5184499) confirms the config tuple is
`(airdrop, primaryStash, secondStash)`.

| Zone | Defaults key | Label string | Icon |
|---|---|---|---|
| AirDrop | `dropzonesAirDropEnabled` | `Send files via AirDrop` (`0x1005683e0`) | asset `AirDropIcon` (only dropzone asset in `Assets.car`) |
| Stash (primary) | `dropzonesFileStashEnabled` | `Keep files temporarily` (`0x100568400`) | `tray.and.arrow.down.fill` (`0x100568460`) |
| Second stash zone | `dropzonesSecondStashZoneEnabled` / `dropzonesAddToStashEnabled` | `Offer Add to Stash as an extra zone` / `Offer Replace Stash as an extra zone` | **`plus.rectangle.on.rectangle`** (add) / **`arrow.triangle.2.circlepath`** (replace) |

**New vs. the old notes:** the *replace* icon is `arrow.triangle.2.circlepath`. The two symbols always
appear as an adjacent pair in the code (`0x1001533ac`/`0x1001533b4`, `0x1001584ac`/`0x1001584b8`,
`0x100158c9c`/`0x100158ca4`, `0x10015b030`/`0x10015b038`, `0x10015e2d8`/`0x10015e2e4`) — the ternary
that picks the second zone's icon.

`arrow.down.circle.fill` (`0x1005685a0`, referenced from `0x100166b50` inside `DropzonesView`) is the
peek/compact indicator. `document.on.document.fill` is the menu-bar stash item's icon
(`StashMenuItem { presenter: FileStackPresenter }`).

`dropzonesStashDropAction ∈ {replace, addToStash}` — "What a drop does when the stash already has
files". When `dropzonesSecondStashZoneEnabled` is on, the *other* action is offered as a third zone
(`hasSecondStashZone`, `threeZone`); `hideAirDrop` collapses back to fewer zones.

Two keys exist for the second zone: `dropzonesSecondStashZoneEnabled` (in the UserDefaults registration
list at file offset 5556736, and in `DropzonesPane._secondStashZoneEnabled`) and
`dropzonesAddToStashEnabled` (referenced from `DropzonesManager` at `0x100159 2fc` / `0x1002ef0c8`).
*(inference: `dropzonesAddToStashEnabled` is the legacy key, still read for migration.)*

### Layout

`DropzonesSplitView` numeric split fractions (decoded inline immediates):

| Value | Address | Reading *(inference)* |
|---|---|---|
| `0.3333…` | `0x10015a088` | three-zone: each card = 1/3 width |
| `0.35` / `0.65` | `0x10015a138`, `0x10015a148`, `0x10015a204`, `0x10015a234`, `0x10015a240`, `0x10015a268` | two-zone split: 35 % / 65 % |
| `0.45` | `0x10015a474`, `0x10015da60`, `0x10015de4c` | a third split/offset fraction |
| `0.04`, `0.12` | `0x10015c20c`, `0x10015c220` | opacity/blur steps for the targeted highlight |
| `1.02` | `0x10015c23c` | **targeted-card scale** (2 % grow on hover) |
| `0.3` | `0x10015cb28` | opacity / transition |

`ZoneCard.isTargeted` drives the highlight; `ZoneCard.actionPreview: String?` supplies a secondary
caption when a zone is targeted; `ZoneCard.canShowFiles` / `isCompactZone` switch between the
"empty zone" look and the "cards over the existing stash" look.

`DropzonesSplitView.AnimationState` is a dedicated `Equatable` struct fed to `withAnimation` /
`.animation(value:)` — its fields (`phase`, `targetedZone`, `hasPendingFiles`, `threeZone`,
`hideAirDrop`, `isSecondZoneDrop`) are exactly the things whose change should animate.

### What happens on a drop

`StashPhase: idle → hovering → hoverExpanded → stashed`. `DropzonesData.pendingFiles` holds the
in-flight drop, `stashedFiles` the settled stash. After the drop the island does **not** collapse
immediately — `DropzonesManager.stashSettleTask` debounces it.

**Decoded debounce/settle durations in `DropzonesManager`** (Swift `Duration` literals, attoseconds):

| Address | Raw | Seconds | Field loaded just before |
|---|---|---|---|
| `0x100155770` | `0x058D15E176280000` | **0.40 s** | `[x22, #0x20]` |
| `0x100155a20` | `0x0429D069189E0000` | **0.30 s** | `[x22, #0x28]` |
| `0x100155c78` | `0x058D15E176280000` | **0.40 s** | `[x22, #0x30]` |
| `0x100156764` | `0x04DB732547630000` | **0.35 s** | `[x22, #0x40]` |

*(inference on the mapping: `stashSettleTask` ≈ 0.40 s, `airDropTask` ≈ 0.30 s, `dragOutTask` ≈ 0.40 s,
plus a 0.35 s task elsewhere in the manager.)*

`FileStackMode` gives away the post-drop animation vocabulary:
`dragging(position:)` → `entering(centerPosition:…)` → `stashed`, and `poofing(position:)` for
removal (a macOS-style poof). `FileStackPresenter` is the observable that drives it, and it is the
same presenter the menu-bar `StashMenuItem` holds — so the stack is shared between island and menu bar.

---

## 4. Stash

### Storage — files are **copied**, not referenced

`StashStorage` (code around `0x10033b700`–`0x10033c800`):

```
let base = FileManager.default.urls(for: .applicationSupportDirectory,   // 0xe
                                    in:  .userDomainMask)               // 0x1
             .first
           ?? FileManager.default.temporaryDirectory                    // fallback
let stashDir = base.appendingPathComponent("Seam/Stash", isDirectory: true)
```

(`URLsForDirectory:inDomains:` at `0x10033c598` with `w2 = 0xe`, `w3 = 0x1`; `temporaryDirectory`
fallback at `0x10033c65c`; the literal `"Seam/Stash"` is built inline as immediates at `0x10033c6d0`.)

→ **`~/Library/Application Support/Seam/Stash/`**. This is why changelog 1.9.2 says "Stashed files
now stay available even after you move or delete the original". (The directory is absent on this
machine because nothing is currently stashed.)

`fileExistsAtPath:` at `0x10033be3c` validates entries on load.

### Index + TTL

- `UserDefaults.standard` key **`stashedFilesData`** — written with `setObject:forKey:` at
  `0x10033c344` after `JSONEncoder().encode(…)` at `0x10033c26c`; read with `dataForKey:` at
  `0x10033bba0` and `JSONDecoder().decode(…)` at `0x10033bbdc`.
  *(inference: the encoded value is `[URL]` — every `stashedFiles`-typed field in the metadata is
  `Array<…>` over `Foundation.URL`, and `Foundation.URL` metadata is used throughout these functions.)*
- `UserDefaults.standard` key **`stashTimestamp`**.
- **`StashStorage.ttl` = 86400.0 s (24 hours).** Decoded at `0x10033bb44`:
  `mov x8, #0x180000000000; movk x8, #0x40f5, lsl #48` → `0x40F5180000000000` = `86400.0`, compared
  against `Date().timeIntervalSince(stashTimestamp)` (`0x10033bb2c`, `fcmp` at `0x10033bb50`).
  If the age is ≥ 24 h the stash is discarded; otherwise `stashedFilesData` is decoded.
- Clearing (`0x10033b740`–`0x10033b8f0`): `removeItem(at:)` on the stash directory, then
  `removeObject(forKey: "stashedFilesData")` and `removeObject(forKey: "stashTimestamp")`.

So: **"Keep files temporarily" = a 24-hour TTL, checked on load, not a quit-time purge.**
No max file count was found.

### `DragStaging` — a *different*, transient directory

`0x100150a20`–`0x100150ae0`:

```
FileManager.default.temporaryDirectory
  .appendingPathComponent("app.seam/DragStaging", isDirectory: true)
  .appendingPathComponent(UUID().uuidString,      isDirectory: true)
```

This is where **promise / data-only drags are materialised** — the path around `0x1001500bc`–`0x10015015c`
does `createDirectory(at:withIntermediateDirectories:…)` then `Data.write(to:options:)`, i.e. it
writes an in-memory pasteboard payload (an image dragged straight out of a browser) to a real file
before it can be stashed. That is changelog 1.12.0 "Images dragged straight out of a browser now
land in the dropzone".

### Reading files off the drag pasteboard

`0x10014fee4` (called from the proximity check with the constant `5.0`):

1. try plain file URLs (`0x1001510a4`);
2. else `pasteboard.readObjects(forClasses: [NSFilePromiseReceiver], options: nil)` (`0x100150010`);
3. `receivePromisedFilesAtDestination:options:operationQueue:reader:` into the `DragStaging`
   UUID folder, on an `OperationQueue` with an explicit `qualityOfService`
   (`0x1001503bc`–`0x100150560`), collected by `PromiseCollector { condition: NSCondition;
   urls: [URL]; settled: Int }`.
4. The `5.0` is the **timeout for waiting on those promises** *(inference — it is the only Double
   argument, a `Date` is taken at `0x1001503fc`, and the collector is an `NSCondition` wait)*.

### Peek / compact and expanded presentation

- Compact/peek: `DropzonesPeekRow { files: [URL]; _totalBytes }` — a row showing the files and a
  **total byte size**; `FileCountCircle { count: Int }` — a count badge; `arrow.down.circle.fill`
  as the idle affordance.
- Expanded: `DropzonesExpandedView { data: DropzonesData }` → `DropzonesThumbnailView { files;
  dragOutPhase }` → `FileThumbnailView` / `StackedThumbnails` / `FileStackView`.
- `StackedThumbnails { files; tokens: ThumbnailStackTokens; rotationSpread: Double }` —
  `ThumbnailStackTokens` = `thumbSize, rotations: [Double], scales: [CGFloat],
  depthOffsets: [CGFloat]?, cornerRadius, compact: Bool, alwaysPreviewStyle: Bool`.
  `0x100337be4` holds `0.017453292519943295` = π/180 → **`rotations` are in degrees** and converted
  to radians at render time.
  `FileStackView { files; isFullyExpanded; dragOutPhase; thumbnailSize; rotationOverflow }`.
  `ThumbnailCardStyle { hasPreview; cornerRadius; compact }` decides the card chrome depending on
  whether a QuickLook preview exists.

**I could not extract the literal `rotations` / `scales` / `depthOffsets` / `thumbSize` /
`cornerRadius` default arrays** — they are built by SwiftUI code with no reachable constant pool
entries in the ranges scanned. Constants recovered near `DropzonesThumbnailView`
(`0x100160000`–`0x100170000`): `0.4`, `0.3`, `0.95`, `1.12`, `0.8`, `0.6`, `50.0`.
*(inference: `0.95` and `1.12` are the appear/press scales, `50.0` a thumbnail point size.)*

### Strings that do **not** exist

Grepping every string in the binary: there is **no** `Clear`, `Remove`, `Reveal in Finder`, `Open`,
`Drop files here`, `%d files`, `Drag out` or `Clear Stash`. **The expanded view has no action
buttons.** `Copy to Clipboard` *is* in the binary but is referenced only from `0x1003c40dc`, deep in
the voice/dictation settings region (next to `copyToClipboard`, `clipboard output mode`) — **it is
not a drop-zone action.** This corrects `seam-analysis.md` §4.

The whole interaction surface is therefore: three drop zones while dragging in; a thumbnail stack you
drag back out; and a menu-bar item. Removal happens by dragging out (`poofing`) or by the 24 h TTL.

---

## 5. Drag-out

`DraggableStashView` is an `NSViewRepresentable` wrapping `DragSourceView : NSView`, tracked by a
`DragSourceMonitor` holding an `NSHashTable<DragSourceView>` (weak, `weakObjectsHashTable` at
`0x10014ee6c`).

`DragSourceView` method list:

```
-initWithFrame:                                              0x10014daa4
-viewDidMoveToWindow                                         0x10014df98
-acceptsFirstMouse:                                          0x10014e0f0
-draggingSession:sourceOperationMaskForDraggingContext:      0x10014eaa8
-draggingSession:willBeginAtPoint:                           0x10014eb38
-draggingSession:endedAtPoint:operation:                     0x10014ec1c
```

### Copy vs. move — decoded exactly

`sourceOperationMaskForDraggingContext:` (`0x10014eb1c`–`0x10014eb24`):

```
cmp  x19, #0x0            ; context
mov  w8, #0x15            ; 21
csinc x0, x8, xzr, ne     ; ne ? 21 : 0+1
```

- `context == .outsideApplication (0)` → **`1` = `.copy` only**
- `context == .withinApplication (1)` → `0x15 = 21` = `.copy | .generic | .move`

This is changelog 1.9.5 "A receiving app can no longer move a file out of your stash".

### Drag items — all files, one item each

`beginDraggingSessionWithItems:event:source:` at `0x10014f278`, preceded by a loop that builds one
`NSDraggingItem(pasteboardWriter:)` per file (`0x10014e760`) — **the whole stash is dragged, not just
one file**. Each writer is a `StashDragItemProvider : NSFilePromiseProvider` with
`fileURL` + `promiseDelegate`.

### Drag image — cascaded 32×32 file icons, *not* the thumbnail stack

`0x10014e7cc`–`0x10014e864`:

```
let icon = NSWorkspace.shared.icon(forFile: path)
icon.size = NSSize(width: 32, height: 32)          // 0x4040000000000000
// item i:
draggingItem.setDraggingFrame(CGRect(x:  Double(i) * 4.0,
                                     y: -Double(i) * 4.0,
                                     width: icon.size.width, height: icon.size.height),
                              contents: icon)
// single/first item uses origin (0, 0)
```

So the drag image is a **cascade of 32 pt Finder icons offset (+4, −4) pt per item**.

### Pasteboard writing / file promises

```
StashDragItemProvider (NSFilePromiseProvider subclass)
  -writableTypesForPasteboard:            0x10033a2d8
  -pasteboardPropertyListForType:         0x10033a52c
  -writingOptionsForType:pasteboard:      0x10033a624
StashFilePromiseDelegate { sourceURL: URL }
  -filePromiseProvider:fileNameForType:                       0x10033a874
  -filePromiseProvider:writePromiseToURL:completionHandler:    0x10033a944
```

Promise-based writing is what made "Dragging a stashed file into a chat app now attaches the file
instead of pasting its location as text" (1.13.3) and "drop into more apps, including WhatsApp" (1.9.5)
work.

### After a successful drag-out

`endedAtPoint:operation:` (`0x10014ec1c`) hops to the main actor, reads a global
(`[x8, #0x928]` = the `DragObserver` singleton) and **clears a flag at `+0xd0`**
(`strb wzr, [x8, #0xd0]`, i.e. `isDragOutActive = false`), then branches on the `operation`
argument into `0x100154684` / `0x10014c6b0`. `DropzonesManager.draggedOutFiles: [URL]` records what
left. *(inference: the stash is **not** cleared by a drag-out — `draggedOutFiles` plus the
`DragOutPhase.completed` state exist so the UI can play the `poofing` animation and then decide;
the 24 h TTL remains the real lifetime. A visual check is needed — see open questions.)*

---

## 6. AirDrop

Plain `NSSharingService`, no picker, no anchoring (`0x100154e0c`–`0x100154e94`):

```
let svc = NSSharingService(named: .sendViaAirDrop)      // GOT 0x1005A5E40 =
                                                        // NSSharingServiceNameSendViaAirDrop
if svc.canPerform(withItems: urls) {                    // canPerformWithItems: 0x100154e58
    svc.perform(withItems: urls)                        // performWithItems:    0x100154e94
} else {
    os_log(…)                                           // nothing user-visible
}
```

- **No `NSSharingServicePicker`** and **no** `sharingService:sourceFrameOnScreenForShareItem:`
  delegate — macOS's own AirDrop sheet appears wherever the system puts it, *not* anchored to the island.
- There is **no "AirDrop not available" string** anywhere in the binary; a failed `canPerform` is
  silent (log only).
- `DropzonesManager.airDropTask` (≈0.30 s, §3) debounces the invocation.

---

## 7. Thumbnails

`ThumbnailManager` (`0x100368f40`–`0x1003690c0`):

```
let scale = NSScreen.main?.backingScaleFactor ?? 2.0            // fmov d9, #2.0 fallback
let px    = requestedSize * 2                                    // fadd d8, d8, d8
let req = QLThumbnailGenerationRequest(fileAt: url,
                                       size: CGSize(width: px, height: px),   // square
                                       scale: scale,
                                       representationTypes: 4)   // .thumbnail
QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { … }
```

- `representationTypes = 4` = `.thumbnail` only (not `.icon`, not `.all`).
- The requested size is **doubled** before being handed to QuickLook, *on top of* the `scale`.
- Fallback: `NSWorkspace.shared.icon(forFile:)` — used at `0x10014e7ac` for drag images, and
  `ThumbnailCardStyle.hasPreview` distinguishes "real QuickLook preview" from "generic icon" in the
  card chrome.
- Cache: `ThumbnailManager` is a class held by `FileThumbnailView` / `StackedThumbnails`; the
  completion block captures a key derived from the URL *(inference: an in-memory dictionary keyed by
  URL + size; no on-disk thumbnail cache exists under `~/Library/Caches/app.seam.Seam/`)*.

---

## 8. Animations, Reduce Motion, settings, menu bar, onboarding

### Animation-ish constants recovered (best effort)

| Value | Where | Likely role *(inference)* |
|---|---|---|
| 0.40 s / 0.30 s / 0.40 s / 0.35 s | `DropzonesManager` | settle / airdrop / dragout task debounces |
| `1.02` | `0x10015c23c` | targeted zone-card scale |
| `0.95`, `1.12` | `0x100162074`, `0x1001620ac` | thumbnail appear / press scales |
| `0.04`, `0.12`, `0.3`, `0.4`, `0.6`, `0.8` | `0x10015c20c`…`0x100162bbc` | opacity / duration steps |
| `50.0` | `0x1001623cc` | thumbnail point size |
| `0.35 / 0.65`, `1/3`, `0.45` | `DropzonesSplitView` | zone width fractions |
| π/180 | `0x100337be4` | degrees → radians for `rotations` |

A general-purpose `SpringInterpolator { current, velocity, stiffness, damping }` class exists in the
binary, but I could not tie specific stiffness/damping values to the dropzone views.

### Reduce Motion

`accessibilityDisplayShouldReduceMotion` appears in the binary
(`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`). It is app-wide, not dropzone-specific.

### Settings pane (`DropzonesPane`) — exact strings

```
dropzonesEnabled                  →  "Show zones when dragging files"
dropzonesAirDropEnabled           →  "Send files via AirDrop"
dropzonesFileStashEnabled         →  "Keep files temporarily"
dropzonesSecondStashZoneEnabled   →  "Offer Add to Stash as an extra zone"
                                  /  "Offer Replace Stash as an extra zone"   (label flips with the action)
dropzonesStashDropAction          →  "What a drop does when the stash already has files"
                                     (a SegmentedPicker — Seam/SegmentedPicker.swift, with the
                                      plus.rectangle.on.rectangle / arrow.triangle.2.circlepath icons)
```

Pane title (Localizable.strings, `en.lproj`): **`Drop Zones`**.
Live defaults on this machine: only `dropzonesEnabled = 1` is written; every other key is unset
(so all sub-toggles default to on, and `stashDropAction` defaults in code).

### Onboarding / feature blurbs

- short: `Drag files near the Surface to AirDrop or stash.` (`0x1005682c0`)
- long: `Drag files near the Surface to quickly AirDrop or stash them for later.` (`0x1005 6a…`,
  file offset 5670960)

### Menu bar

`StashMenuItem { presenter: FileStackPresenter }` with icon `document.on.document.fill`. It shares
the same `FileStackPresenter` as the island, so it shows the same `[URL]` + `FileStackMode`
(`dragging` / `entering` / `poofing` / `stashed`). *(inference: it is a drag source too, since the
presenter is the only state it holds and `DragSourceMonitor` tracks views globally.)*

---

## 9. Marketing / changelog (getseam.app)

`https://getseam.app` — no mention of drop zones at all. Tagline "Save an hour every day from the
top of your screen." Sub-pages: `/download`, `/buy` ($19.90), `/faqs`, `/changelog`, `/features`,
`/blog`. Current version 1.14.7.

`https://getseam.app/features` — Drop Zones is listed under **Productivity** with exactly one line:
**"Temporary file storage for drag and drop"**. No screenshots or video URLs were exposed in the
fetched content.

`https://getseam.app/changelog` — the feature's whole history, and the single most useful behavioural
source:

| Version | Entry (verbatim) |
|---|---|
| 1.13.3 | "Dragging a stashed file into a chat app now attaches the file instead of pasting its location as text" |
| 1.13.3 | "Pick what a drop onto a full stash does by default, replace it or add to it, and keep the other action one zone away" |
| 1.12.0 | "Images dragged straight out of a browser now land in the dropzone" |
| 1.10.2 | "Files dropped on an external display's drop zone now land in the stash as expected instead of ending up on the desktop" |
| 1.9.5 | "Files dragged out of the stash now drop into more apps, including WhatsApp" |
| 1.9.5 | "A receiving app can no longer move a file out of your stash when you drag it out" |
| 1.9.2 | "Stashed files now stay available even after you move or delete the original" |
| 1.9.2 | "Smoother dragging of items straight from the browser, Mail, and Photos" |
| 1.8.21 | "Files dropped onto the notch now land reliably every time" |
| 1.8.14 | "Dropping a file into the stash no longer leaves a stray copy on your desktop" |
| 1.8.13 | "Dragging a file into the stash no longer nudges the original out of place on your desktop" |
| 1.1.12 | "New three-zone layout lets you add files to your stash or replace it, with a dedicated setting to choose your preferred behavior" |
| 1.1.12 | "Smoother transitions and animations when dragging files" |
| 1.1.6 | "Smoother thumbnail appearance on hover" |
| 1.1.4 | "Improved reliability when dragging files in quick succession" |
| 1.1.0 | "Choose which zones to show: AirDrop only, File Stash only, or both" |
| 1.1.0 | "Smoother drag-out animations" / "Files no longer accidentally land in a disabled zone" / "More reliable dismiss when dragging files out" |

Two behavioural confirmations worth pulling out: 1.8.13/1.8.14 ("no stray copy on your desktop",
"no longer nudges the original") mean the catcher window must swallow the drop cleanly so the
Finder/Desktop never also sees it — consistent with a full-screen catcher window above the Surface.

---

## Recommendation for the clone

1. **Trigger** — copy Seam exactly: `NSEvent.addGlobalMonitorForEvents` for
   `.leftMouseDown / .leftMouseDragged / .leftMouseUp / .flagsChanged`, plus
   `NSPasteboard(name: .drag).changeCount` snapshotted on mouse-down. No CGEvent tap, no timer.
   Gate the zones on `CGRect(x: screen.midX-150, y: screen.maxY-120, w: 300, h: 220).contains(NSEvent.mouseLocation)`.
   Special-case `org.chromium.chromium-initiated-drag`.
2. **Window** — a separate borderless `NSWindow` per screen, `styleMask: .nonactivatingPanel`,
   `backing: .buffered`, `level = surfaceWindow.level + 1` (fallback `.statusBar + 2`),
   `collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`,
   `isOpaque=false`, `backgroundColor=.clear`, `hasShadow=false`, `alphaValue = 0`,
   `ignoresMouseEvents` toggled (`true` idle / `false` shown), frame = the whole `screen.frame`.
   **Do not** use SkyLight/CGS private spaces — Seam doesn't.
   Register `NSFilePromiseReceiver.readableDraggedTypes + [.fileURL, .URL, .png, .tiff, .string]`.
3. **Zones** — model with `ZoneState(airdrop, stash, hasSecondStashZone, stashDropAction)`,
   1–3 `ZoneCard`s split 1/1 (35 %/65 %) or 1/3 each; icons `AirDropIcon` equivalent,
   `tray.and.arrow.down.fill`, `plus.rectangle.on.rectangle`, `arrow.triangle.2.circlepath`;
   targeted card scales to 1.02. Animate off a dedicated `Equatable` AnimationState struct.
4. **Stash** — copy files into `~/Library/Application Support/<App>/Stash/`, index in UserDefaults
   (`stashedFilesData` JSON `[URL]` + `stashTimestamp`), **TTL 86400 s** checked on load.
   Materialise promise/data-only drags into `tmp/<bundle>/DragStaging/<uuid>/` with a 5 s promise
   timeout via `NSCondition`. No action buttons in the expanded view.
5. **Drag-out** — one `NSFilePromiseProvider` subclass per file, all files in one
   `beginDraggingSession`; `sourceOperationMask` = `.copy` outside the app, `[.copy,.generic,.move]`
   inside; drag image = cascaded 32×32 `NSWorkspace.icon(forFile:)` offset (+4,−4) per item.
6. **AirDrop** — `NSSharingService(named: .sendViaAirDrop)`, `canPerform` → `perform`, no picker,
   no anchoring, silent failure.
7. **Thumbnails** — `QLThumbnailGenerationRequest(fileAt:size: 2×requested square, scale: backingScaleFactor ?? 2,
   representationTypes: .thumbnail)` via `QLThumbnailGenerator.shared`, in-memory cache,
   `NSWorkspace.icon(forFile:)` fallback; debounces 0.3–0.4 s.

### Open questions — need a screen recording of Seam's drop-zone flow

1. Do the zones **fade/slide in** from the notch, and over what duration? (Only fractions were
   recoverable, not the SwiftUI `Animation` values.)
2. What exactly does the **peek row** look like with files present — stacked rotated thumbnails, a
   single thumbnail + count circle, or a row? (`DropzonesPeekRow` has `files` + `_totalBytes`;
   `FileCountCircle` has `count`. Is the total byte size actually rendered?)
3. `ThumbnailStackTokens` literals: how many cards are visible in the stack, what rotation spread
   (degrees), what scale falloff, what corner radius, what `thumbSize`?
4. **Is the stash cleared after a successful drag-out?** (`draggedOutFiles` + `DragOutPhase.completed`
   exist but the branch could go either way.) Drag files out and check whether the island still
   shows them.
5. What does the **`poofing`** animation look like, and what triggers it — drag-out completion,
   or only an explicit removal gesture? Is there *any* way to remove one file (no such strings exist)?
6. Does the **AirDrop sheet** appear centred by the system or near the notch?
7. With three zones, what are the **labels/sublabels actually rendered on the cards** (the settings
   strings are the only labels in the binary — do the cards show "AirDrop" / "Stash" / "Add"?),
   and what is `ZoneCard.actionPreview` showing when a zone is targeted?
8. Does the island **collapse** after the ~0.4 s settle, or stay expanded showing the stack?
9. Menu-bar `document.on.document.fill` item: click behaviour (popover? drag source? both?).
