# Drop Zones on macOS 26 — feasibility study for Notch

Target: Seam-parity "Drop Zones" (§4 of `research/seam-analysis.md`). Written against
macOS 26.5.2 (25F84), Xcode 26.6, Swift 6.3.3, SDK `MacOSX26.5.sdk`. Citations are to
the SDK headers on this machine (`$(xcrun --show-sdk-path --sdk macosx)/System/Library/Frameworks/…`),
which are the authoritative version of the Apple docs for the toolchain we build with.

Marked **[verified]** = observed by running the spike on this machine.
**[header]** = read out of the SDK header. **[assumed]** = reasoning, not yet tested.

---

## 0. The spike

`spikes/DropSpike/` — a standalone SwiftPM executable (Swift 6 language mode, ~360 lines,
not referenced by `project.yml`, touches no app code). Run it with a single command:

```
swift run -c release --package-path /Users/vladislavzidko/Desktop/notch/spikes/DropSpike DropSpike
```

What you get: two 400×160 panels just under the notch on the built-in screen —
**A = private SkyLight space** (created exactly like `NotchKit/Sources/IslandCore/Surface/PrivateSpace.swift`:
`SLSSpaceCreate(cid, 1, 0)` → `SLSSpaceSetAbsoluteLevel(…, 400)` → `SLSShowSpaces` →
`SLSSpaceAddWindowsAndRemoveFromSpaces(…, 7)`), **B = ordinary space**, both
`.borderless + .nonactivatingPanel` at `CGWindowLevelForKey(.statusWindow) + 1` (26) with
`SurfaceWindow`'s collection behaviour. A `⬇︎Spike` status-bar menu has *AirDrop temp file*,
*Thumbnail test* and *Quit*. Quit from that menu (or Ctrl-C) — quitting destroys the private
space; a leaked shown space is a visible artifact until logout.

**What to do while it runs** (this is the manual test the study depends on):

1. Drag a file from Finder over **A**, then over **B**. Watch stdout for
   `ENTERED / PERFORM / EXITED` and which panel turns green. *This is the load-bearing
   question: does a window in a private SkyLight space receive dragging-destination callbacks?*
2. Watch for `DRAG START via globalMonitor` vs `DRAG START via poll 100ms`, and for a
   `DRAG END via globalMonitor .leftMouseUp` line. Drag from Finder, from Chrome, and
   from Mail. Also drag a selected chunk of text (should log `DRAG(non-file)`).
3. Drag **out** of a panel: press inside the `drag OUT ⇩ promise` strip (upper of the two
   labels) or the `drag OUT ⇩ plain URL` strip and drag to Finder / Mail / Slack. stdout
   prints `drag-out ENDED op=…`.
4. Status menu → *AirDrop temp file*: does the picker appear, where, and does it need
   `NSApp.activate()`?

Headless parts can be smoke-tested without a human:
`DROPSPIKE_SELFTEST=1 swift run -c release --package-path …/spikes/DropSpike DropSpike`
runs the thumbnail + AirDrop-capability checks and exits after 4 s.

Selftest output on this machine **[verified]**:

```
space id=1399 cid=1134015 setLevel=0 show=0        # show/adopt rc is NOT a status code, see below
A · PRIVATE SPACE: registered types = ["public.file-url"]
adopt window 7018 -> space 1399: rc=0
panels up: private=7018 plain=7019 level=26 space=ok
global monitors installed: 2/2 (trusted=false)
AirDrop: service=ok canPerform=true
QL shot.png: type=2 size=(96.0, 64.0) 16ms
QL dropspike.txt: type=2 size=(96.0, 96.0) 17ms
```

**Side finding, relevant to the backlog [verified]:** across two runs of the identical binary,
`SLSShowSpaces` and `SLSSpaceAddWindowsAndRemoveFromSpaces` returned `55525376` on one run and
`0` on the other, while the space worked (visible panel, correct level) in **both**. Only
`SLSSpaceSetAbsoluteLevel` returned a stable `0`. So their return values are **not** reliable
error codes — which matters for the backlog item *"`PrivateSpace.init?` fails open — return nil
instead"*: gating the initializer on `show != 0` would intermittently disable the island. Gate
on `SLSSpaceCreate() != 0` and on `SLSSpaceSetAbsoluteLevel`, not on `SLSShowSpaces`.

---

## 1. Detecting a system-wide drag

### Strategies and what they cost

| Strategy | Permission | Notes |
|---|---|---|
| `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp])` | **none** **[verified]** | `AXIsProcessTrusted() == false` and both monitors installed. Mouse/scroll/flags masks never needed Accessibility; only `.keyDown`/`.keyUp`/`.flagsChanged` (and `NSEvent.isSwipeTrackingFromScrollEventsEnabled`-independent key taps) do. `HoverMonitor` in `IslandCore` already relies on this for `.mouseMoved`. |
| `CGEvent.tapCreate(… .listenOnly …)` for mouse events | **Accessibility** (Input Monitoring for HID-level taps) | What Seam adds on top (`DragObserver.swift` references an event tap). Only needed if global monitors are starved mid-drag — see the open question below. |
| `NSPasteboard(name: .drag)` polling | **none** **[verified]** | No TCC gate for pasteboard reads on macOS (the "pasteboard access" alert is iOS-only). Non-sandboxed, so no entitlement either. |
| `NSView.registerForDraggedTypes` on an always-visible catcher window | none | Only fires once the pointer is already over our window — too late to *expand* the island in anticipation. Needed as well, for the drop itself. |

**Recommendation**: global `NSEvent` monitor as the trigger, `NSPasteboard(name: .drag)` as
the source of truth, and a short low-rate poll as a safety net only while a drag might be in
flight. Do *not* run a permanent 100 ms timer in production — the spike does, purely so the
manual test can tell the two paths apart; an always-on 10 Hz timer contradicts
`docs/superpowers/notes/2026-09-11-idle-cost.md`.

### Reading the drag pasteboard

`NSPasteboardNameDrag` is the system-wide drag pasteboard **[header** `NSPasteboard.h:49`,
`API_AVAILABLE(macos(10.13))`; the old `NSDragPboard` is deprecated at `:531`**]**.

```swift
let pb = NSPasteboard(name: .drag)
guard pb.changeCount != lastSeen else { return }   // cheap: an Int, no IPC decode
lastSeen = pb.changeCount
let urls = pb.readObjects(forClasses: [NSURL.self],
                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
```

- **`changeCount` is the drag identity.** It increments once per drag session start. Seam's
  `_draggingUID` is the same idea. Use it to dedupe, and to decide "this is a *new* drag"
  rather than "the pointer moved again".
- **File vs other payloads**: a file drag carries `public.file-url` (`.fileURL`); reading with
  `NSURL.self` + `.urlReadingFileURLsOnly: true` yields `[]` for a text/image drag or for a
  remote `https:` URL drag out of Safari, which is exactly the discriminator we want. Check
  `pb.types` for logging only; do not switch on it (apps advertise a long tail: `NSFilenamesPboardType`
  legacy, `public.file-promise-url`, Chrome's `org.chromium.chromium-initiated-drag`).
- **File promises from other apps** (Mail attachments, Photos): the pasteboard carries
  `com.apple.pasteboard.promised-file-url` / `NSFilesPromisePboardType` and **no** `public.file-url`.
  Those drags will look like "non-file" to the check above; to accept them you must
  `registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise as String)])`
  and use `NSFilePromiseReceiver` in `performDragOperation`. **[assumed]** — worth a second
  spike pass if you want Photos/Mail drags into the stash. Seam's feature list does not
  clearly cover it either.
- **Cost**: `changeCount` is a fast IPC round trip; `readObjects` is not. Read objects only
  when the count actually changed.

### Detecting drag end

Three signals, in order of reliability:

1. `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp])` — the natural one.
   **Open risk:** while the WindowServer is running a drag session, mouse events are routed
   through the drag machinery and may not be delivered to global monitors of unrelated
   processes. The spike prints which path fires; this is the single most important thing the
   manual test answers. If global monitors go quiet mid-drag, the fallbacks are (a) polling
   `CGEvent(source: nil)`/`NSEvent.pressedMouseButtons` at ~30 Hz for the duration, or
   (b) an Accessibility-gated `CGEventTap` (what Seam does) — the latter would be the first
   TCC prompt Notch ever needs, so prefer (a).
2. Our own `draggingExited` / `performDragOperation` — tells us the drag left/ended *on us*.
3. A timeout (e.g. collapse the zones 10 s after the last evidence of a live drag) as a
   backstop against a missed end event leaving the island stuck open.

`NSEvent.pressedMouseButtons` (a static, no monitor needed) is a cheap synchronous "is the
button still down?" check usable from a timer — recommended for the (a) fallback.

---

## 2. Can a window in a private SkyLight space receive drops?

**Unknown before the spike; the spike is the answer.** What is known:

- Drag destination routing is done by the WindowServer hit-testing the window list under the
  cursor, then AppKit delivering `NSDraggingDestination` messages to the view registered for
  the type. Nothing in the public API is space-aware; the private space is still a real,
  *shown* space composited above the user's space, and its window has a normal
  `windowNumber` (7018 above) **[verified]**.
- Counter-evidence to watch for: the space is created with `SLSSpaceCreate(cid, 1, 0)` and the
  window is removed from all other spaces (`…AddWindowsAndRemoveFromSpaces(…, 7)`). If the
  WindowServer scopes drag hit-testing to the *active* space, panel A will get nothing and
  panel B will get everything.
- Related known-good data point: the island already receives ordinary mouse clicks in the
  private space today (`PassThroughHostingView.hitTest` works), so the window is in the normal
  event hit-test path. Drag destinations go through a different WindowServer path, so this is
  suggestive, not conclusive.

**Contingency if A does not receive drops**: keep the island in the private space and add a
*separate* `DropCatcherWindow` in the ordinary space (Seam's design: a borderless window shown
only while a drag is in flight, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
.stationary, .ignoresCycle]`, level `.statusWindow + 1`), positioned exactly over the island's
zone rects and made click-through otherwise. This is strictly more code but is the safe design,
and it is what Seam ships — which is itself weak evidence that a private-space window *cannot*
take the drop.

---

## 3. `NSDraggingDestination` details

`NSView` conforms to `NSDraggingDestination` directly **[header** `NSView.h:81`**]**.
`NSWindow` does **not** — it only exposes `registerForDraggedTypes:` **[header** `NSWindow.h:814`**]**
and forwards the destination messages to its *delegate*. Register on the view; it is simpler
and lets each zone card be its own destination.

Callback order (all `NS_SWIFT_UI_ACTOR`, i.e. `@MainActor`, **[header** `NSDragging.h:116-132`**]**):

```
draggingEntered:  -> NSDragOperation      // [] means "reject", and no further updates
draggingUpdated:  -> NSDragOperation      // every mouse move; keep it allocation-free
draggingExited:                            // or:
prepareForDragOperation: -> Bool           // last chance to refuse
performDragOperation:    -> Bool           // read the pasteboard HERE
concludeDragOperation:                     // UI settle
draggingEnded:                             // always, even when rejected
```

- **Return value**: `.copy` (raw 1) for both zones. `.link` (2) is for alias/reference
  semantics and shows a different badge; `.move` (16) tells the *source* to delete its
  original — never return it for AirDrop or the stash. `[]` (`.none`, 0) rejects.
  **[header** `NSDragging.h:25-37`**]**
- `draggingUpdated` is called on every mouse-moved event over the window. Use it to switch the
  highlighted zone (`TargetedZone` in Seam's vocabulary) by hit-testing the point; return the
  same operation every time. Implement `wantsPeriodicDraggingUpdates -> false` unless you need
  autoscroll — it avoids a timer while the pointer is stationary.
- **Reading multiple URLs**: `sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
  options: [.urlReadingFileURLsOnly: true])` returns all items in order. Read it in
  `performDragOperation`, not in `draggingEntered` — entering is fired continuously and the
  read is the expensive part. (The spike deliberately reads on entry, to print the file list.)
- `numberOfValidItemsForDrop` lets you show "3" on the badge under the cursor;
  `draggingFormation` (`.default/.none/.pile/.list/.stack` **[header** `NSDragging.h:39-46`**]**)
  reshapes the dragged images — setting `.stack` during `draggingEntered` is a cheap way to
  make an incoming multi-file drag *look* like the stacked stash card before it lands.
  `animatesToDestination = true` (inspected between `prepareForDragOperation` and
  `performDragOperation` **[header** `NSDragging.h:88`**]**) animates the images into our frames.
- **Security scoping: none needed.** Notch is not sandboxed (like Seam — `research/seam-analysis.md`
  §4 notes zero `bookmark` strings in the binary), so a plain `URL` from the drag pasteboard is
  readable indefinitely. Do **not** add `startAccessingSecurityScopedResource`; it is a no-op
  outside a sandbox and would be dead code that implies a sandbox we do not have.
- `springLoading*` (macOS 10.11+) is what makes a Finder folder open on hover. Irrelevant here,
  but note `draggingEnded:` is only called once if you implement both protocols.

---

## 4. Dragging back out of the stash

### Source side

`NSView.beginDraggingSession(with:event:source:)`; `NSWindow` also gained one on macOS 15
**[header** `NSWindow.h:810`**]** — use the view's.

- **Does the panel need to become key?** No — but the view must return `true` from
  `acceptsFirstMouse(for:)`, otherwise the first click into a non-active app's window is
  swallowed as an activation click and `mouseDragged` never arrives. `SurfaceWindow` is
  `.nonactivatingPanel` with `canBecomeKey == false`, so *every* click is a first click. The
  spike sets `acceptsFirstMouse` on `ZoneView` and prints `key=false` when the session starts;
  the manual test confirms a drag-out works from a never-key window. **[assumed → spike]**
- `draggingSession(_:sourceOperationMaskFor:)` — return `[.copy]` for
  `.outsideApplication` and `[]` for `.withinApplication`. **Do not return `.move`** even
  though "the file leaves the stash" feels like a move: `.move` asks the *destination* to
  delete our source file, and our source is the user's real file. Correct stash semantics are
  **copy + clear-on-success**: in `draggingSession(_:endedAt:operation:)`, if
  `operation.contains(.copy)`, remove the item from the stash model ourselves.
- `draggingSession(_:willBeginAt:)` / `movedToPoint:` / `endedAt:operation:` are the lifecycle.
  The `operation` in `endedAt` is `.none` (0) when the user dropped on nothing or hit Escape.
- **Drag image**: `NSDraggingItem.setDraggingFrame(_:contents:)` with an `NSImage`. For the
  stash card, render the fanned stack (or the top thumbnail plus an `×N` badge) into an
  `NSImage` once and reuse it. One `NSDraggingItem` per file gives the destination a real
  multi-item drag and lets the formation animate; a single item with a composite image is
  simpler but drops as one file. **Prefer one item per file.**

### `NSFilePromiseProvider` vs a plain `NSURL` pasteboard item

| | plain `url as NSURL` | `NSFilePromiseProvider` |
|---|---|---|
| What the destination gets | `public.file-url` pointing at the *original* file | a promise; the destination asks us to write the bytes at a location it chooses |
| Finder | copies/moves the original (a *move* would relocate the user's real file) | writes a fresh copy into the drop folder |
| Mail / Slack / most upload targets | usually fine — they read the URL | fine; this is the path that works when the file must be materialised |
| Cost | zero | we must copy/write bytes in the delegate |

**Recommendation**: send **both representations** — one `NSDraggingItem` whose pasteboard
writer is the `NSURL`, *plus* a promise — is not possible for a single item, so instead pick
per item: the stash holds real existing files, so **plain `NSURL` is the right default**
(zero copy, Finder/Mail/Slack all handle it, and it is what preserves the filename and type).
Use `NSFilePromiseProvider` only for stash entries whose bytes are *not* already a file on
disk (e.g. a stashed clipboard image), or if the manual test shows a destination that refuses
the URL drag. Seam ships the promise path, which is consistent with it also stashing
non-file content and with its `app.seam/DragStaging` staging directory.

Promise delegate contract **[header** `NSFilePromiseProvider.h:37-50`**]**:

- `filePromiseProvider(_:fileNameForType:)` — **`NS_SWIFT_UI_ACTOR`**, i.e. `@MainActor`.
  Return a base filename only; do not write yet.
- `filePromiseProvider(_:writePromiseTo:completionHandler:)` — **`NS_SWIFT_NONISOLATED`**,
  called on the queue returned below; write to the supplied URL and always call the handler.
- `operationQueue(for:)` — **`@MainActor`**, optional; returning your own `OperationQueue`
  keeps the copy off the main thread (default is `OperationQueue.main`, which would block the
  island's UI while copying a large file). **Always implement it.**
- **`delegate` is `weak`** **[header** `:26`**]** — the provider will silently produce nothing
  if you let the delegate die. Hold it (the spike uses a singleton). `userInfo` (`:29`) is the
  documented place to stash the source URL.

---

## 5. AirDrop via `NSSharingService`

```swift
guard let svc = NSSharingService(named: .sendViaAirDrop) else { return }
svc.delegate = self
guard svc.canPerform(withItems: urls) else { return }
svc.perform(withItems: urls)
```

- `NSSharingServiceNameSendViaAirDrop` **[header** `NSSharingService.h:30`, macOS 10.8+**]**.
  Items must be `NSPasteboardWriting` (so `URL` works) **[header** `:127`**]**.
- **`canPerform(withItems:) == true` for an accessory, un-bundled `swift build` executable
  on this machine [verified]** — the service exists and accepts a file URL without a bundle,
  an Info.plist or a code signature beyond ad-hoc. Whether the *picker window* actually appears
  and where it lands is the part the manual test answers (a share sheet normally anchors to a
  window/view of the frontmost app).
- Delegate callbacks, all `@MainActor` **[header** `NSSharingService.h:161-184`**]**:
  `sharingService(_:willShareItems:)`, `didShareItems:`, `didFailToShareItems:error:`,
  and for positioning: `sharingService(_:sourceFrameOnScreenForShareItem:)` (the frame the
  transition animation flies out of — point it at the zone card), `transitionImageForShareItem:contentRect:`,
  and `sharingService(_:sourceWindowForShareItems:sharingContentScope:)` (return the island
  panel; set the out-param to `.item` — `NSSharingContentScopeItem` is the documented value for
  "a clearly identified file represented by its icon" **[header** `:147-157`**]**).
- `NSSharingServicePicker` (declared in the same header, `:256`) is the multi-service sheet with
  `NSSharingServicePickerDelegate`; it is anchored via
  `show(relativeTo:of:preferredEdge:)`. We do **not** need it — the AirDrop zone goes straight
  to the one service. Keep it in mind only if you later want a generic "Share" zone.
- **Activation-policy caveat**: with `.accessory`/LSUIElement the app is never the frontmost
  app, and AppKit panels presented from a background app can appear behind the active app or
  refuse to take focus. If the picker does not show, the fix ladder is:
  `NSApp.activate(ignoringOtherApps: true)` immediately before `perform` → present from a
  temporary ordinary (`.regular`) window → set the activation policy to `.regular` for the
  duration of the share and back to `.accessory` afterwards. Expect to need at least the first
  rung. **[assumed → spike]**

---

## 6. Thumbnails — `QLThumbnailGenerator`

```swift
let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                       scale: 2, representationTypes: .thumbnail)
QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in … }
```

- Representation types **[header** `QLThumbnailRepresentation.h:17-21`**]**:
  `.icon` = 0 (system file-type icon, may ignore your parameters), `.lowQualityThumbnail` = 1
  (cache hit / cheap render), `.thumbnail` = 2 (final, matches the request). The mask you pass
  is the set you are *willing* to accept; `generateBestRepresentation` calls back **once** with
  the best available, `generateRepresentations` calls back progressively (icon → low → final),
  which is the right one for a card that should paint instantly and sharpen.
- **[verified]** on this machine, `.thumbnail` only, 96×96 @2×: a PNG returned `type=2` in
  **16 ms**, a plain `.txt` returned `type=2` (a rendered text preview) in **17 ms**. Both
  callbacks land on a background queue. Note the PNG came back `(96, 64)` — QL preserves aspect
  ratio and `size` is a bounding box, so the card layout must not assume a square image.
- `rep.nsImage` requires AppKit linkage; `rep.contentRect` (macOS 12+) is the document area
  inside an icon-mode image, useful to crop the paper-with-fold decoration away.
- **Caching**: key on `URL.path + contentModificationDate + size/scale`. A stash of 20 files at
  96×96 @2× is ~20 × 192×192 × 4 B ≈ 3 MB of bitmaps — acceptable, but cap the cache (an
  `NSCache` with `countLimit` ≈ 64 and `totalCostLimit` ≈ 16 MB) so a user who stashes a folder
  of 500 photos does not regress `docs/superpowers/notes/2026-09-11-idle-cost.md`. Do not hold
  `CGImage`s for files no longer in the stash.
- **Fallback**: `NSWorkspace.shared.icon(forFile:)` is synchronous, never fails, and is the
  right placeholder to draw while the generator is in flight and the permanent answer when it
  errors (`err != nil`, e.g. a file that disappeared mid-drag).

---

## 7. Stash persistence

Seam keeps its index in `UserDefaults` (`stashedFilesData` + `stashTimestamp`,
`research/seam-analysis.md` §4). For Notch, prefer an explicit file —
`~/Library/Application Support/Notch/stash.json` — because it is inspectable, diffable and
does not bloat the defaults plist that the settings UI also reads.

```json
{ "version": 1,
  "updatedAt": "2026-09-12T10:00:00Z",
  "items": [ { "id": "UUID", "path": "/Users/…/report.pdf", "displayName": "report.pdf",
               "addedAt": "2026-09-12T09:59:00Z", "byteSize": 12345,
               "contentModifiedAt": "2026-09-01T12:00:00Z" } ] }
```

- **Plain paths, not security-scoped bookmarks.** Notch is not sandboxed, so bookmarks buy
  nothing and cost a resolve (which can block on network volumes). Seam made the same call.
  *If* the app is ever sandboxed, this is the one decision to revisit.
- Write atomically (`Data.write(to:options:.atomic)`), debounced (Seam's `stashSettleTask`),
  never on the main actor.
- **Missing files**: check `FileManager.default.fileExists` lazily — on load, on window show,
  and immediately before a drag-out or AirDrop. Do not `stat` on a timer. Render a missing
  item greyed with a "file moved" affordance and let the user dismiss it; silently dropping
  entries is worse, because the usual cause is an unmounted external volume that will come back.
- The stash is explicitly temporary ("Keep files temporarily"). Recommend an expiry (24 h,
  or on next launch) applied on load, and never copying bytes into a staging directory until a
  drag-out actually needs materialising (Seam's `app.seam/DragStaging` is lazily populated —
  inference, per §4).

---

## 8. Swift 6 concurrency shape

| Piece | Isolation |
|---|---|
| Catcher window, zone views, all `NSDraggingDestination` methods | `@MainActor` — the protocol is `NS_SWIFT_UI_ACTOR` in the SDK, so this is enforced, not a choice. |
| `NSDraggingSource` callbacks | `@MainActor`, same reason. |
| Drag watcher (`NSEvent` monitors) | `@MainActor` class. The monitor handler closure is `@Sendable`; inside it use `MainActor.assumeIsolated { … }` (global mouse monitors are delivered on the main run loop, so this is sound) rather than `Task { @MainActor in }`, which would reorder events and allocate per mouse-move. `HoverMonitor` currently uses `Task`; the drag path is hotter and should not. |
| `NSFilePromiseProviderDelegate` | Mixed by design: `fileNameForType` and `operationQueue(for:)` are `@MainActor`; `writePromiseTo:completionHandler:` is `NS_SWIFT_NONISOLATED` and runs on the queue you return. Make the delegate a `final class … : NSObject, @unchecked Sendable` holding immutable state, or an actor-free type whose only mutable state is confined to that queue. Keep it alive yourself — `delegate` is `weak`. |
| `QLThumbnailGenerator` callback | Non-isolated, background queue. `QLThumbnailRepresentation` is not `Sendable`: convert to what you need (`NSImage`/`CGImage` + size) inside the closure and hop with `Task { @MainActor in … }`, or use the `async` bridge if you add one. |
| Stash store | An `actor` owning the JSON file + in-memory list, with a `@MainActor @Observable` projection for SwiftUI — same split the project already uses for the music feature. |
| `NSSharingService` delegate | `@MainActor` (all callbacks are `NS_SWIFT_UI_ACTOR`). |

The spike compiles clean under `swiftLanguageMode(.v6)` with exactly this shape, which is the
cheapest evidence that the production code can too.

---

## 9. Risks and unknowns the manual test settles

1. **Does panel A (private SkyLight space) get `draggingEntered`/`performDragOperation` at all?**
   If not, we need a separate catcher window in the ordinary space (Seam's `DropCatcherWindow`),
   kept in sync with the island's zone rects — noticeably more code and a new class of
   "the two windows disagree" bugs.
2. **Do global `NSEvent` monitors keep firing *during* an active drag session?** If the
   WindowServer starves them, the "expand the island when a drag starts" trigger needs either a
   ~30 Hz poll (`NSEvent.pressedMouseButtons` + drag-pasteboard `changeCount`) or an
   Accessibility-gated event tap. The latter would be Notch's first TCC prompt.
3. **Is the drag pasteboard populated at the moment the drag starts**, or only once the pointer
   enters a registered destination? If the latter, we cannot know a drag is *file* content until
   it is already over us, and the zones would have to expand optimistically for any drag.
4. **Chrome / Electron drags.** Seam special-cases `org.chromium.chromium-initiated-drag`.
   Verify whether a Chrome image/file drag shows up as `DRAG(non-file)` and whether the drop
   still yields a file URL.
5. **Does a drag-out start from a never-key `.nonactivatingPanel`** with only
   `acceptsFirstMouse`? And does the click that starts it get eaten by `PassThroughHostingView.hitTest`
   when the same pattern is ported into `SurfaceView`?
6. **`op=` on drop into Finder / Mail / Slack** — plain `NSURL` vs `NSFilePromiseProvider`.
   Specifically whether Mail's compose window accepts the plain URL (it historically prefers
   promises) and whether Finder ever reports `.move` (which we must then not honour).
7. **Does the AirDrop picker appear for an accessory app, and where?** If it needs
   `NSApp.activate`, the island loses its "never steals focus" property for the duration of a
   share — decide whether that is acceptable or whether a `.regular` shim window is worth it.
8. **Escape / dropped-on-nothing** — confirm `endedAt:operation:` reports `.none` so the stash
   is not cleared by a cancelled drag-out.

## Spike results (user-driven runs, 2026-09-12)

Round 1 (`dropspike.log`), panels side by side:
- Panel A (private SkyLight space, level 26) **never received** `draggingEntered`/`performDragOperation`
  for a Finder file drag dropped on it (mouse-up landed inside its frame; nothing logged).
- Panel B (normal space, same level) received the full sequence: `ENTERED → PREPARE → PERFORM
  (ops=55) → CONCLUDE` with the file URL.
- Global monitors fired **during** the drag session (`DRAG START via globalMonitor
  .leftMouseDragged` with the file list) and at the end (`.leftMouseUp`), with
  `AXIsProcessTrusted() == false`. The very first drag was seen once with an empty type list
  (pasteboard not yet populated) — detection must re-check the drag pasteboard for a few hundred
  ms after the first drag event, or poll `changeCount` at ~100 ms while the button is down.
- Drag-out with a plain `NSURL` pasteboard item ended with `.copy`; the file promise variant wrote
  the promised file on a background thread and also ended with `.copy`.

Round 2 (`dropspike2.log`), private-space panels stacked exactly over normal-space panels:
- A (private, `ignoresMouseEvents = true`) over B: **B received the drop.**
- C (private, `ignoresMouseEvents = false`) over D: **D received the drop.**
- Conclusion: a private-space window is invisible to drag hit-testing — it neither receives drops
  nor blocks the normal-space window beneath it.

Design consequence: keep the island (zones UI) in the private space and add an invisible,
ordinary-space `DropCatcherWindow` (borderless non-activating `NSPanel`, level statusWindow+1,
`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, clear background, frame = the island's
expanded frame) that is ordered in only while a file drag is in flight. It forwards
`draggingEntered/Updated/Exited/performDragOperation` (cursor location in island coordinates,
file URLs) to the feature. This is exactly Seam's `DropCatcherWindow`.

AirDrop picker: not exercised in either run (no `AirDrop:` lines); `canPerform` is verified true.
To be verified in the real build.
