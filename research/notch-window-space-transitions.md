# Keeping a notch overlay window visible over fullscreen AND stationary during Space transitions

Research date: 2026-09-11. All code below was read from the current `main` of each repo
(raw.githubusercontent.com) — quotes are verbatim.

---

## TL;DR

**No collection-behavior / window-level combination solves this.** Every project that only uses
`collectionBehavior` (NotchDrop, DynamicNotchKit, SuperIsland, cyclop, CodeIsland, opennook) has the
same behaviour you measured: the panel rides along with the Space transition.

The three projects whose notch is genuinely immune to Space transitions all do the *same* thing:
they create their **own private CGS/SkyLight Space at a very high absolute level**
(`2147483647`), make it permanently visible (`CGSShowSpaces` / `SLSShowSpaces`), and **move the
notch window into that Space** (`CGSAddWindowsToSpaces` / `SLSSpaceAddWindowsAndRemoveFromSpaces`).
A window that lives in a separate, always-shown, top-level Space is not a participant in the
Dock/WindowServer Space-switch animation at all — it is composited above every Space, so its
`x` never changes and it is on-screen on fullscreen Spaces too.

The boring.notch commit that introduced it says exactly this:

> `970f875b` (2024-10-28) — "Put the notch window in a space that sits at the highest level,
> allowing it to ignore most of macos window managment and overlay on top of everything"

---

## 1. TheBoredTeam/boring.notch — SOLVED, via private CGS Space

### 1a. The window class (nothing special — same as ours)

`boringNotch/components/Notch/BoringNotchWindow.swift` (legacy) and
`boringNotch/components/Notch/BoringNotchSkyLightWindow.swift` (current) are `NSPanel` subclasses:

```swift
class BoringNotchSkyLightWindow: NSPanel {
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

`level = .mainMenu + 3` → 24 + 3 = **27**. `styleMask` comes from the caller:

```swift
let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
```

Note this collection behavior is **identical to ours** (the one that slides). It is *not* what fixes
the problem — it is kept only so AppKit doesn't fight the panel.

### 1b. The actual fix — `NotchSpaceManager` + `CGSSpace`

`boringNotch/managers/NotchSpaceManager.swift` (16 lines, whole file):

```swift
class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let notchSpace: CGSSpace
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {
        notchSpace = CGSSpace(level: 2147483647) // Max level
    }
}
```

`boringNotch/private/CGSSpace.swift` (adapted from avaidyam/Parrot):

```swift
public final class CGSSpace {
    private let identifier: CGSSpaceID

    public var windows: Set<NSWindow> = [] {
        didSet {
            let remove = oldValue.subtracting(self.windows)
            let add = self.windows.subtracting(oldValue)

            CGSRemoveWindowsFromSpaces(_CGSDefaultConnection(),
                                       remove.map { $0.windowNumber } as NSArray,
                                       [self.identifier])
            CGSAddWindowsToSpaces(_CGSDefaultConnection(),
                                  add.map { $0.windowNumber } as NSArray,
                                  [self.identifier])
        }
    }

    public init(level: Int = 0) {
        let flag = 0x1 // this value MUST be 1, otherwise, Finder decides to draw desktop icons
        self.identifier = CGSSpaceCreate(_CGSDefaultConnection(), flag, nil)
        CGSSpaceSetAbsoluteLevel(_CGSDefaultConnection(), self.identifier, level)
        CGSShowSpaces(_CGSDefaultConnection(), [self.identifier])
    }

    deinit {
        CGSHideSpaces(_CGSDefaultConnection(), [self.identifier])
        CGSSpaceDestroy(_CGSDefaultConnection(), self.identifier)
    }
}
```

Private symbols are bound with `@_silgen_name` (link-time, **not** `dlsym`):

```swift
@_silgen_name("_CGSDefaultConnection")     fileprivate func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate")            fileprivate func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceSetAbsoluteLevel")  fileprivate func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces")     fileprivate func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSRemoveWindowsFromSpaces")fileprivate func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces")             fileprivate func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces")             fileprivate func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
```

### 1c. Wiring — `boringNotch/boringNotchApp.swift`

```swift
private func createBoringNotchWindow(for screen: NSScreen, with viewModel: BoringViewModel) -> NSWindow {
    let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
    let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]

    let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
    ...
    window.contentView = NSHostingView(rootView: ContentView().environmentObject(viewModel))

    window.orderFrontRegardless()
    NotchSpaceManager.shared.notchSpace.windows.insert(window)
    ...
}
```

Order matters: `orderFrontRegardless()` **first** (so `windowNumber` is valid), then insert into the
Space. On teardown/screen change they remove it again:
`NotchSpaceManager.shared.notchSpace.windows.remove(window)`.

### 1d. Notification handling

- **No** `NSWorkspace.activeSpaceDidChangeNotification` observer at all — they don't need one.
- `NSApplication.didChangeScreenParametersNotification` → reposition / recreate windows.
- `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` (DistributedNotificationCenter) → toggle
  the *SkyLight* lock-screen Space (a **different**, second private Space at level 400) so the notch
  survives the lock screen. `undelegateWindow` uses `dlsym("SLSRemoveWindowsFromSpaces")`.
- Fullscreen *detection* (for the optional "hide in fullscreen" feature) is a separate concern:
  `boringNotch/observers/FullscreenMediaDetection.swift` consumes an async stream from
  `MacroVisionKit.FullScreenMonitor.shared.spaceChanges()`. It is only used to hide content, never to
  fix positioning.
- **No two-window scheme.** One window per screen, one Space.

### 1e. Evidence it actually works on current macOS

- Open issue **#1059 "[Bug] Notch displayed over the space labels in Mission Control"**, reported on
  **macOS 26.3**: "open Mission Control → Notch blocks spaces selector and controls". That is a
  direct observation that the window is composited *above* Mission Control and does not move with it.
- Multiple issues ask to *hide* the notch in fullscreen (#1278, #663, #254, #239), i.e. it is
  unambiguously visible over fullscreen apps.
- Space-transition bugs #330 / #410 were closed long ago.

---

## 2. MrKai77/DynamicNotchKit — NOT solved (plain collection behavior)

`Sources/DynamicNotchKit/Utility/DynamicNotchPanel.swift` (whole class):

```swift
final class DynamicNotchPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.hasShadow = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
    }
    override var canBecomeKey: Bool { true }
}
```

`DynamicNotch.swift`:

```swift
let panel = DynamicNotchPanel(
    contentRect: .zero,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: true
)
...
panel.orderFrontRegardless()
windowController = .init(window: panel)
```

- **No** `.fullScreenAuxiliary`, **no** `.fullScreenNone`, **no** `.ignoresCycle`.
- No private API, no CGS/SkyLight, no Space observers. The only notification observed is
  `NSApplication.didChangeScreenParametersNotification` (line 146), which triggers
  `initializeWindow(screen:)` → `deinitializeWindow()` + create a fresh panel (window **re-creation**
  on screen change only, not on Space change).
- Single window. Nothing here addresses the slide.

---

## 3. Other open-source notch apps

### 3a. monuk7735/mew-notch — SOLVED, same private-Space technique

`MewNotch/Utils/NotchSpaceManager.swift` is a near-verbatim copy of boring.notch's, including the
comment:

```swift
class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let notchSpace: CGSSpace
    private init() {
        notchSpace = CGSSpace(level: 2147483647) // Max level
    }
}
```

Window (`MewNotch/View/Common/MewWindow.swift`):

```swift
class MewPanel: NSPanel {
    ...
    collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    canBecomeVisibleWithoutLogin = true
    level = .mainMenu + 1
    hasShadow = false
}
```

Attach (`MewNotch/Utils/NotchManager.swift`):

```swift
panel = MewPanel(contentRect: screen.frame,
                 styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
                 backing: .buffered, defer: true)
...
panel.orderFrontRegardless()
windows[screen] = panel

if addToSeparateSpace {
    if notchDefaults.shownOnLockScreen {
        WindowManager.shared?.moveToLockScreen(panel)
    } else {
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
}
```

Note the **either/or**: the window lives in *one* private Space — either the notch Space
(level `Int32.max`) or the lock-screen Space (level 400). `MewNotch/Utils/Managers/WindowManager.swift`
resolves SkyLight via `CFBundleGetFunctionPointerForName` and documents the absolute-level table:

```swift
enum CGSSpaceLevel: Int32 {
    case kCGSSpaceAbsoluteLevelDefault = 0
    case kCGSSpaceAbsoluteLevelSetupAssistant = 100
    case kCGSSpaceAbsoluteLevelSecurityAgent = 200
    case kCGSSpaceAbsoluteLevelScreenLock = 300
    case kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock = 400
    case kCGSSpaceAbsoluteLevelBootProgress = 500
    case kCGSSpaceAbsoluteLevelVoiceOver = 600
}
...
let _ = SLSSpaceAddWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
```

### 3b. jackson-storm/DynamicNotch — SOLVED, cleanest modern implementation (SkyLight/SLS)

`DynamicNotch/Core/SystemBridges/SkyLightOperator.swift`:

```swift
enum SkyLightSpaceLevel: Int32, CaseIterable {
    case notchSurface = 2_147_483_647
    case lockScreenOverlay = 400
    case lockScreenNotchOverlay = 401
}
```

```swift
let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
// SLSMainConnectionID, SLSSpaceCreate, SLSSpaceSetAbsoluteLevel, SLSShowSpaces,
// SLSSpaceAddWindowsAndRemoveFromSpaces
let connection = mainConnectionID()
for level in SkyLightSpaceLevel.allCases {
    let space = spaceCreate(connection, 1, 0)
    guard space != 0 else { continue }
    _ = spaceSetAbsoluteLevel(connection, space, level.rawValue)
    _ = showSpaces(connection, [space] as CFArray)
    spaces[level] = space
}
```

```swift
func delegateWindow(_ window: NSWindow, to level: SkyLightSpaceLevel = .notchSurface) {
    _ = addWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
}
```

Window config (`OverlayPanelFactory.swift` / `OverlayWindowLevel.swift`):

```swift
static func collectionBehavior(includesFullscreenAuxiliary: Bool = true) -> NSWindow.CollectionBehavior {
    var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    if includesFullscreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
    return behavior
}
static func configure(_ window: NSPanel, level: NSWindow.Level, isFloatingPanel: Bool = true) {
    window.isReleasedWhenClosed = false
    window.isFloatingPanel = isFloatingPanel
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hidesOnDeactivate = false
    window.isMovable = false
    window.hasShadow = false
    window.animationBehavior = .none
    window.level = level
    window.collectionBehavior = collectionBehavior()
    window.acceptsMouseMovedEvents = true
}
static let interactiveNotch = NSWindow.Level.mainMenu + 3
```

Wiring (`AppDelegate+Window.swift`):

```swift
window = OverlayPanelFactory.makePanel(frame: frame, level: OverlayWindowLevel.interactiveNotch)
window.contentView = hostingView
window.collectionBehavior = OverlayPanelFactory.collectionBehavior(includesFullscreenAuxiliary: true)
SkyLightOperator.shared.delegateWindow(window, to: .notchSurface)
```

It also queries fullscreen state *without* `NSWorkspace` notifications, via
`CGSCopyManagedDisplaySpaces` (`"Current Space"["type"] == 4` ⇒ fullscreen space):

```swift
func isFullscreenSpaceActive(on screen: NSScreen) -> Bool { ... currentSpaceType.intValue == 4 }
```

This is a better fullscreen signal than `activeSpaceDidChangeNotification` (which, as you measured,
fires *after* the animation).

### 3c. Lakr233/SkyLightWindow (the SPM package boring.notch depends on)

`Sources/SkyLightWindow/SkyLightOperator.swift` — the canonical reference, with the C prototypes in
comments:

```swift
// extern int SLSMainConnectionID(void);
// extern int SLSSpaceCreate(int cid, int one, int zero);
// extern CGError SLSSpaceSetAbsoluteLevel(int cid, int sid, int level);
// extern CGError SLSShowSpaces(int cid, CFArrayRef space_list);
// extern CGError SLSSpaceAddWindowsAndRemoveFromSpaces(int cid, int sid, CFArrayRef array, int seven);
```

```swift
connection = SLSMainConnectionID()
space = SLSSpaceCreate(connection, 1, 0)
_ = SLSSpaceSetAbsoluteLevel(connection, space, SKL_CGSSpaceLevel.kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock.rawValue)
_ = SLSShowSpaces(connection, [space] as CFArray)

public func delegateWindow(_ window: NSWindow) {
    _ = SLSSpaceAddWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
}
```

Its `TopmostWindow` uses `level = .init(rawValue: .init(Int32.max - 2))` plus the same four
collection-behavior flags, and `canBecomeVisibleWithoutLogin = true`.

### 3d. Lakr233/NotchDrop — NOT solved (this is the config that slides)

`NotchDrop/NotchWindow.swift`:

```swift
class NotchWindow: NSWindow {
    ...
    collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    level = .statusBar + 8 // kills ibar lol
    hasShadow = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

`NotchWindowController.swift`: `styleMask: [.borderless, .fullSizeContentView]`, then
`window.makeKeyAndOrderFront(nil)`. No Space APIs, no Space notifications, one window per screen.
Same family as your current setup.

### 3e. Also checked (all in the "no fix" family — collection behavior only)

| Project | level | collectionBehavior | Space APIs | Space notifications |
|---|---|---|---|---|
| shobhit99/SuperIsland `IslandPanel` | `.statusBar` | `[.canJoinAllSpaces, .stationary, .ignoresCycle]` (also `animationBehavior = .none`) | none | `activeSpaceDidChangeNotification` + 2 s poll, **only** to `orderOut`/`orderFrontRegardless` for the "hide on fullscreen" option |
| wxtsky/CodeIsland `PanelWindowController` | `CGWindowLevelForKey(.mainMenuWindow) + 2` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` | none | `activeSpaceDidChangeNotification` → `isActiveSpaceFullscreen()` |
| akalikbergenov/cyclop `NotchPanel` | `CGWindowLevelForKey(.statusWindow) + 1` (= 26, same as yours) | `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]` | none | none |
| twinkling-reality/opennook `NookPanel` | `.statusBar + 8` | `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]` | none | none |

opennook's comment is worth quoting because it states the public-API mental model precisely (and
shows they never solved the slide):

> `.canJoinAllSpaces` + `.stationary` keep the chrome pinned across Spaces;
> `.fullScreenAuxiliary` lets it stay visible when another app goes fullscreen
> (without it the notch UI vanishes the moment any window is fullscreened);
> `.ignoresCycle` keeps the panel out of Cmd-Tab and the window cycle.

**Nobody uses a two-window scheme** (`.fullScreenNone` window + fullscreen window). I found zero
instances of that pattern in any of the repos surveyed.

---

## 4. `.stationary` vs `.transient` vs "sticky" (`CGSSetWindowTags`)

- **`NSWindowCollectionBehaviorStationary`** (Apple docs / *Setting Window Collection Behavior*):
  the window is *unaffected by Exposé* — it stays visible and stationary, like the desktop window.
  It is an **Exposé/Mission-Control** hint. Critically, it says nothing about the Space-switch
  slide animation, and empirically it does not stop it: the WindowServer's Space transition moves
  the *whole space layer*, and a `canJoinAllSpaces` window is re-parented into the destination space
  and dragged along with it. `.stationary` only exempts the window from the Exposé *scatter*.
- **`NSWindowCollectionBehaviorTransient`** is the opposite of `.stationary`: the window is removed
  (hidden) when Exposé/Mission Control is invoked. It is what you'd use for a HUD you want to
  disappear during Mission Control — this is the public-API answer to boring.notch's issue #1059.
- **"Sticky" (`CGSSetWindowTags` with `kCGSStickyTagBit`, bit `0x0800`)** is the *pre-Spaces-era*
  private equivalent of `canJoinAllSpaces`: read the current tags with `CGSGetWindowTags`, OR in
  `0x00000800`, write back with `CGSSetWindowTags(cid, wid, &tags, 32)`. It makes a window appear on
  every Space. It is **not** a fix for the slide — it has the same semantics as
  `.canJoinAllSpaces` (the window is a member of every space, so it still participates in the
  transition), and it does not get you onto native fullscreen spaces on modern macOS. No notch app
  surveyed uses it. Treat it as a dead end.
- **Absolute Space level** (`CGSSpaceSetAbsoluteLevel` / `SLSSpaceSetAbsoluteLevel`) is the only
  mechanism in this family that changes *which layer the window is composited into*, which is why it
  is the one that works.

---

## 5. What this implies about Seam

Your measurements of Seam (one window, level 26, `x` never changes, on-screen on fullscreen spaces)
are the exact CGWindowList signature of a window living in a private top-level Space: the AppKit
`level` is untouched (still 26, because the Space, not the level, does the lifting), the window is
always `kCGWindowIsOnscreen`, and it never moves.

The strings you found (`setCollectionBehavior:`, `orderFrontRegardless`) are ObjC **selector** names
— every Swift call site emits those into `__objc_methname`, so they carry no information.
`FullscreenManager` / `FullscreenScope` / `showInFullScreen` / `bypassFullscreen` are consistent with
a policy layer ("should the island be shown while an app is fullscreen?"), not with a positioning fix.

Before concluding Seam has a private-API-free trick, re-check for the symbols properly — with
`@_silgen_name` (boring.notch's style) the CGS functions are **undefined dynamic symbols**, not
`__cstring` literals, so `strings` will miss them:

```sh
nm -u /Applications/Seam.app/Contents/MacOS/Seam | grep -Ei 'CGSSpace|CGSAddWindows|SLSSpace|SLSShowSpaces|SLSMainConnectionID|DefaultConnection'
otool -L /Applications/Seam.app/Contents/MacOS/Seam        # SkyLight.framework linked?
otool -I -v /Applications/Seam.app/Contents/MacOS/Seam | grep -Ei 'CGSSpace|SLSSpace'
strings -a - /Applications/Seam.app/Contents/MacOS/Seam | grep -Ei 'SkyLight|SLSSpace|CGSSpace'
```

Also check any embedded frameworks in `Seam.app/Contents/Frameworks/` — `SkyLightWindow` is
distributed as an SPM package and may be statically merged or shipped as a separate dylib.

---

## 6. Recommendation for our app (ranked by evidence)

### Rank 1 — Private SkyLight Space at max absolute level (strong evidence: 3 shipping apps, current macOS)

Keep the panel exactly as it is (level 26 or `.mainMenu + 3`; keep
`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`; `animationBehavior = .none`;
`styleMask [.borderless, .nonactivatingPanel]`), and add this on top:

```swift
import AppKit

@MainActor
final class NotchSpace {
    static let shared = NotchSpace()

    private typealias F_MainConnectionID = @convention(c) () -> Int32
    private typealias F_SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_HideSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SpaceDestroy = @convention(c) (Int32, Int32) -> Int32
    private typealias F_AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var addWindows: F_AddWindowsAndRemoveFromSpaces?
    private var hideSpaces: F_HideSpaces?
    private var destroy: F_SpaceDestroy?
    private(set) var isAvailable = false

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let pCid  = dlsym(h, "SLSMainConnectionID"),
              let pNew  = dlsym(h, "SLSSpaceCreate"),
              let pLvl  = dlsym(h, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(h, "SLSShowSpaces"),
              let pAdd  = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return }

        connection = unsafeBitCast(pCid, to: F_MainConnectionID.self)()
        space = unsafeBitCast(pNew, to: F_SpaceCreate.self)(connection, 1, 0)   // the "1" MUST be 1
        guard space != 0 else { return }

        _ = unsafeBitCast(pLvl,  to: F_SpaceSetAbsoluteLevel.self)(connection, space, 2_147_483_647)
        _ = unsafeBitCast(pShow, to: F_ShowSpaces.self)(connection, [space] as CFArray)

        addWindows = unsafeBitCast(pAdd, to: F_AddWindowsAndRemoveFromSpaces.self)
        hideSpaces = dlsym(h, "SLSHideSpaces").map { unsafeBitCast($0, to: F_HideSpaces.self) }
        destroy    = dlsym(h, "SLSSpaceDestroy").map { unsafeBitCast($0, to: F_SpaceDestroy.self) }
        isAvailable = true
    }

    /// Call AFTER orderFrontRegardless() — windowNumber must be valid (non-zero).
    func adopt(_ window: NSWindow) {
        guard isAvailable, window.windowNumber > 0, let addWindows else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)  // 7 = remove from all other spaces
    }

    func teardown() {
        guard isAvailable else { return }
        _ = hideSpaces?(connection, [space] as CFArray)
        _ = destroy?(connection, space)
    }
}
```

Call sites:

```swift
panel.orderFrontRegardless()      // first — establishes windowNumber
NotchSpace.shared.adopt(panel)    // then — moves it into the private space
```

Rules that matter (all learned from the three working implementations):

1. **Order**: `orderFrontRegardless()` → `adopt()`. `windowNumber` is 0 before the window is
   realized, and the call silently no-ops.
2. **Re-adopt** every time you recreate/close+reopen the panel or move it to another screen
   (boring.notch and mew-notch both remove-then-reinsert around `didChangeScreenParameters`).
   `SLSSpaceAddWindowsAndRemoveFromSpaces(..., 7)` is idempotent, so it is safe to call again.
3. `SLSSpaceCreate(cid, 1, 0)` — the middle argument must be `1`; boring.notch's comment:
   *"this value MUST be 1, otherwise, Finder decides to draw desktop icons"*.
4. Create the space **once**, app-wide (a singleton). Hide + destroy it in
   `applicationWillTerminate` — the Parrot comment warns *"Initialized `CGSSpace`s MUST be
   de-initialized upon app exit!"* (a leaked shown space is a visible artifact until logout).
5. Keep `.fullScreenAuxiliary` in `collectionBehavior`. All three working apps do; it is harmless
   once the window is in the private space and it keeps behaviour sane if the private space fails
   to initialize.
6. **Drop the `activeSpaceDidChangeNotification` handler** for positioning. It is useless (fires
   after the animation) and once the window is in its own space there is nothing to fix.
7. **Guard everything**: if any `dlsym` fails, fall back to today's behaviour (slide but visible)
   rather than crashing. All three projects treat SkyLight as optional.

Known side effects you are signing up for (all observed in boring.notch):
- The panel draws **above Mission Control**, including over the Spaces strip (issue #1059, macOS
  26.3). If you care, observe Mission Control (e.g. `com.apple.expose.awake`
  DistributedNotification, or poll `CGSCopyManagedDisplaySpaces`) and `orderOut(nil)`.
- It also sits above the screen saver / above most system UI. `2147483647` is deliberately maximal;
  you can pick a lower absolute level (e.g. `500` = BootProgress, `300` = ScreenLock) to slot it
  under specific system layers — the level table in mew-notch's `WindowManager` is the map.
- The lock screen needs a **second** space at level `400`
  (`kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`) — a window can only be in one space at a
  time, so you swap it on `com.apple.screenIsLocked` / `screenIsUnlocked` (boring.notch and
  mew-notch both do exactly this). Skip entirely if you don't want a lock-screen island.
- App Store review: these are private APIs. All three apps ship outside the Mac App Store.

### Rank 2 — CoreGraphics variant of the same thing (equivalent, slightly weaker evidence)

boring.notch's `CGSSpace.swift` binds `CGSSpaceCreate` / `CGSSpaceSetAbsoluteLevel` /
`CGSShowSpaces` / `CGSAddWindowsToSpaces` with `@_silgen_name` instead of `dlsym`. Functionally the
same (CoreGraphics forwards to SkyLight). Prefer Rank 1's `dlsym` form: it degrades gracefully if a
future macOS drops a symbol, whereas `@_silgen_name` produces a **launch-time dyld crash**.

### Rank 3 — Replace `activeSpaceDidChange` with `CGSCopyManagedDisplaySpaces` polling

Independently useful regardless of the above: for "is the current space a fullscreen space?" use
jackson-storm's approach — `CGSCopyManagedDisplaySpaces(cid)`, find the entry whose
`"Display Identifier"` matches the screen UUID, and test `["Current Space"]["type"] == 4`. It gives
you the fullscreen state immediately instead of after the 0.3 s animation.

### Rank 4 — Two-window scheme (`.fullScreenNone` + fullscreen twin): NOT recommended

Zero of the surveyed projects do this. It cannot work cleanly anyway: the `.fullScreenAuxiliary`
twin is the one that slides, so you would still see the slide on every fullscreen enter/exit, just
on a different window. Do not pursue.

### Rank 5 — `CGSSetWindowTags` sticky bit: dead end

Same semantics as `.canJoinAllSpaces`; does not change space membership layering. No evidence any
notch app uses it.

---

## Sources

Source code (raw, read 2026-09-11):
- https://raw.githubusercontent.com/TheBoredTeam/boring.notch/main/boringNotch/components/Notch/BoringNotchWindow.swift
- https://raw.githubusercontent.com/TheBoredTeam/boring.notch/main/boringNotch/components/Notch/BoringNotchSkyLightWindow.swift
- https://raw.githubusercontent.com/TheBoredTeam/boring.notch/main/boringNotch/managers/NotchSpaceManager.swift
- https://raw.githubusercontent.com/TheBoredTeam/boring.notch/main/boringNotch/private/CGSSpace.swift
- https://raw.githubusercontent.com/TheBoredTeam/boring.notch/main/boringNotch/boringNotchApp.swift
- https://raw.githubusercontent.com/TheBoredTeam/boring.notch/main/boringNotch/observers/FullscreenMediaDetection.swift
- https://github.com/TheBoredTeam/boring.notch/commit/970f875b (introduces the private Space)
- https://raw.githubusercontent.com/MrKai77/DynamicNotchKit/main/Sources/DynamicNotchKit/Utility/DynamicNotchPanel.swift
- https://raw.githubusercontent.com/MrKai77/DynamicNotchKit/main/Sources/DynamicNotchKit/DynamicNotch/DynamicNotch.swift
- https://raw.githubusercontent.com/Lakr233/NotchDrop/main/NotchDrop/NotchWindow.swift
- https://raw.githubusercontent.com/Lakr233/NotchDrop/main/NotchDrop/NotchWindowController.swift
- https://raw.githubusercontent.com/Lakr233/SkyLightWindow/main/Sources/SkyLightWindow/SkyLightOperator.swift
- https://raw.githubusercontent.com/Lakr233/SkyLightWindow/main/Sources/SkyLightWindow/TopmostWindow.swift
- https://raw.githubusercontent.com/monuk7735/mew-notch/main/MewNotch/Utils/NotchSpaceManager.swift
- https://raw.githubusercontent.com/monuk7735/mew-notch/main/MewNotch/Utils/NotchManager.swift
- https://raw.githubusercontent.com/monuk7735/mew-notch/main/MewNotch/Utils/Managers/WindowManager.swift
- https://raw.githubusercontent.com/monuk7735/mew-notch/main/MewNotch/View/Common/MewWindow.swift
- https://raw.githubusercontent.com/jackson-storm/DynamicNotch/main/DynamicNotch/Core/SystemBridges/SkyLightOperator.swift
- https://raw.githubusercontent.com/jackson-storm/DynamicNotch/main/DynamicNotch/Application/Panels/OverlayPanelFactory.swift
- https://raw.githubusercontent.com/jackson-storm/DynamicNotch/main/DynamicNotch/Application/Windows/OverlayWindowLevel.swift
- https://raw.githubusercontent.com/jackson-storm/DynamicNotch/main/DynamicNotch/Application/AppDelegate/AppDelegate%2BWindow.swift
- https://raw.githubusercontent.com/shobhit99/SuperIsland/main/SuperIsland/Window/IslandWindow.swift
- https://raw.githubusercontent.com/shobhit99/SuperIsland/main/SuperIsland/Window/IslandWindowController.swift
- https://raw.githubusercontent.com/twinkling-reality/opennook/main/Sources/NookSurface/Internal/NookPanel.swift
- https://raw.githubusercontent.com/akalikbergenov/cyclop/main/Sources/Cyclop/Notch/NotchPanel.swift
- https://raw.githubusercontent.com/wxtsky/CodeIsland/main/Sources/CodeIsland/PanelWindowController.swift

Issues:
- https://github.com/TheBoredTeam/boring.notch/issues/1059 (notch draws over Mission Control, macOS 26.3)
- https://github.com/TheBoredTeam/boring.notch/issues/1278, /663, /254, /239 (requests to hide it in fullscreen)
- https://github.com/TheBoredTeam/boring.notch/issues/330, /410 (older space-switch bugs, closed)

Docs / discussion:
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/WinPanel/Articles/SettingWindowCollectionBehavior.html
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary
- https://developer.apple.com/forums/thread/26677 (canJoinAllSpaces + fullScreenAuxiliary does NOT put you over fullscreen; no public solution)
- https://github.com/slint-ui/slint/discussions/11000 (screenSaver level + canJoinAllSpaces/stationary/ignoresCycle/fullScreenNone)
- https://github.com/shabble/osx-space-id/blob/master/CGSPrivate.h (CGSSetWindowTags / sticky bit 0x0800)
- https://cocoadev.github.io/CoreGraphicsPrivate/
- https://github.com/avaidyam/Parrot (original CGSSpace wrapper)
