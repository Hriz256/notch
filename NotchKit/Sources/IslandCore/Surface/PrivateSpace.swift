import AppKit
import os

/// A private WindowServer Space, created through SkyLight, that sits at a very high
/// *absolute* level and holds the island panel.
///
/// Why this exists: a window that merely joins every Space (`.canJoinAllSpaces`) is
/// re-parented into the destination Space during a Space switch, so the WindowServer
/// drags it along with the 0.3 s transition animation — the island visibly slides
/// sideways whenever a full-screen app is entered/exited or Mission Control opens.
/// Neither the window `level` nor any collection-behavior combination changes that:
/// the transition moves the whole Space layer. Moving the window into a *separate*
/// Space that is permanently shown at a top absolute level takes it out of every user
/// Space, so it is composited above all of them and never participates in the
/// transition — while remaining visible over full-screen apps.
///
/// Absolute level table (from SkyLight) — these are the only values WindowServer
/// accepts, and they composite in ascending order (0 < 100 < 300 < 400 < 600):
///
///     0    kCGSSpaceAbsoluteLevelDefault
///     100  kCGSSpaceAbsoluteLevelSetupAssistant
///     200  kCGSSpaceAbsoluteLevelSecurityAgent
///     300  kCGSSpaceAbsoluteLevelScreenLock
///     400  kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock
///     500  kCGSSpaceAbsoluteLevelBootProgress
///     600  kCGSSpaceAbsoluteLevelVoiceOver
///
/// Anything above 600 is treated as *invalid*, not as "higher": measured on macOS 26.5
/// (z-order sampled with `CGWindowListCopyWindowInfo` during a Dock minimize), a space
/// at `Int32.max` — and at 1 000 or 100 000 — composites *below* a space at 100 and
/// below the Dock's Genie animation. So the `Int32.max` that boring.notch, mew-notch
/// and jackson-storm's DynamicNotch ship is a silent downgrade, not a top level.
///
/// We use 400, which is what the commercial Seam ships (and what Lakr233's
/// SkyLightWindow uses). Every valid level 100…600 sits above the Dock minimize
/// animation; 400 is the lowest that clears it with headroom while staying *below*
/// VoiceOver — 600 would additionally cover the VoiceOver cursor, which we do not want.
///
/// Symbols are resolved at runtime with `dlopen`/`dlsym`: SkyLight is a private
/// framework, so it is never linked at build time, and a missing symbol on a future
/// macOS degrades to "no private space" (the plain panel, which slides but works)
/// instead of a launch-time dyld crash.
@MainActor
public final class PrivateSpace {
    /// Absolute level of the private Space. Must be one of the valid SkyLight levels
    /// (0, 100, 200, 300, 400, 500, 600) — larger values are rejected by WindowServer
    /// and sink the space below level 100. 400 matches Seam and sits above the Dock's
    /// minimize animation; see the table above before changing it.
    public static var absoluteLevel: Int32 = 400

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias HideSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpacesFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private let logger = Logger(subsystem: "app.notch", category: "surface.space")

    private let connection: Int32
    private let spaceID: UInt64
    private let addWindows: AddWindowsAndRemoveFromSpacesFn
    private let showSpaces: ShowSpacesFn
    private let hideSpaces: HideSpacesFn?
    private let spaceDestroy: SpaceDestroyFn?
    /// Optional: ``release(_:)`` is the only caller, and without it the window simply
    /// stays in the private Space (the island keeps working, the drag image stays under it).
    private let getActiveSpace: GetActiveSpaceFn?
    private var isAlive = true

    /// The WindowServer id of the created Space. Useful for verification.
    public var identifier: UInt64 { spaceID }

    /// Creates and shows the private Space. Returns `nil` when SkyLight or any required
    /// symbol is unavailable, or when the Space could not be created — callers should
    /// fall back to the plain panel.
    public init?() {
        // The handle is intentionally never `dlclose`d: SkyLight stays loaded for the
        // lifetime of the process and the resolved function pointers must stay valid.
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else { return nil }
        guard let pConnection = dlsym(handle, "SLSMainConnectionID"),
              let pCreate = dlsym(handle, "SLSSpaceCreate"),
              let pSetLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(handle, "SLSShowSpaces"),
              let pAdd = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return nil }

        let connection = unsafeBitCast(pConnection, to: MainConnectionIDFn.self)()
        // The middle argument MUST be 1; with any other value Finder starts drawing
        // desktop icons into the space (boring.notch's `CGSSpace` carries the same note).
        let space = unsafeBitCast(pCreate, to: SpaceCreateFn.self)(connection, 1, 0)
        guard space != 0 else { return nil }

        let setLevel = unsafeBitCast(pSetLevel, to: SpaceSetAbsoluteLevelFn.self)
        let show = unsafeBitCast(pShow, to: ShowSpacesFn.self)

        // Order matters: create → set absolute level → show → (later) add the window.
        let level = Self.absoluteLevel
        let levelResult = setLevel(connection, space, level)
        let showResult = show(connection, [space] as CFArray)

        self.connection = connection
        self.spaceID = space
        self.addWindows = unsafeBitCast(pAdd, to: AddWindowsAndRemoveFromSpacesFn.self)
        self.showSpaces = show
        self.hideSpaces = dlsym(handle, "SLSHideSpaces").map {
            unsafeBitCast($0, to: HideSpacesFn.self)
        }
        self.spaceDestroy = dlsym(handle, "SLSSpaceDestroy").map {
            unsafeBitCast($0, to: SpaceDestroyFn.self)
        }
        self.getActiveSpace = dlsym(handle, "SLSGetActiveSpace").map {
            unsafeBitCast($0, to: GetActiveSpaceFn.self)
        }
        if getActiveSpace == nil {
            logger.warning("SLSGetActiveSpace unavailable; the island cannot leave its private space")
        }

        logger.info("""
            Created private space id=\(space, privacy: .public) \
            level=\(level, privacy: .public) cid=\(connection, privacy: .public) \
            setLevel=\(levelResult, privacy: .public) show=\(showResult, privacy: .public)
            """)
        if levelResult != 0 || showResult != 0 {
            logger.error("""
                Private space setup returned non-zero: \
                setLevel=\(levelResult, privacy: .public) show=\(showResult, privacy: .public)
                """)
        }
    }

    /// Moves `window` into the private Space, removing it from every other Space.
    ///
    /// Must be called *after* `orderFrontRegardless()` — `windowNumber` is 0 until the
    /// window is realized and the call would silently no-op. Idempotent, so re-adopting
    /// a rebuilt window is safe.
    public func adopt(_ window: NSWindow) {
        guard isAlive else { return }
        let number = window.windowNumber
        guard number > 0 else {
            logger.error("Cannot adopt window with invalid windowNumber \(number, privacy: .public)")
            return
        }
        // The trailing 7 is the documented "remove from all other spaces" selector.
        let result = addWindows(connection, spaceID, [number] as CFArray, 7)
        if result == 0 {
            logger.info("""
                Adopted window \(number, privacy: .public) \
                into space \(self.spaceID, privacy: .public)
                """)
        } else {
            logger.error("""
                Failed to adopt window \(number, privacy: .public) into \
                space \(self.spaceID, privacy: .public): error \(result, privacy: .public)
                """)
        }
    }

    /// Moves `window` back out of the private Space and into the user's *active* one —
    /// the inverse of ``adopt(_:)``.
    ///
    /// Why anyone would want that: the private Space composites above every user Space,
    /// which puts the island above Finder's drag-image window too, so a file dragged onto
    /// the island vanishes behind it. A window in the active Space is composited with
    /// everything else in it and the drag image draws on top, the way it does in Seam.
    /// The cost is that the window rides Space transitions again for as long as it is
    /// out — acceptable while the user is holding a drag.
    ///
    /// The call is the same atomic add-and-remove as ``adopt(_:)``, so the window is
    /// never in neither Space: there is nothing to flash. Idempotent, and a no-op when
    /// `SLSGetActiveSpace` did not resolve (logged once, at init).
    public func release(_ window: NSWindow) {
        guard isAlive else { return }
        guard let getActiveSpace else { return }
        let number = window.windowNumber
        guard number > 0 else {
            logger.error("Cannot release window with invalid windowNumber \(number, privacy: .public)")
            return
        }
        let active = getActiveSpace(connection)
        guard active != 0 else {
            logger.error("SLSGetActiveSpace returned no space; window \(number, privacy: .public) stays private")
            return
        }
        // Same trailing 7 — "remove from all other spaces" — which is what takes the
        // window out of ours as it joins the active one.
        let result = addWindows(connection, active, [number] as CFArray, 7)
        if result == 0 {
            logger.info("""
                Released window \(number, privacy: .public) \
                into active space \(active, privacy: .public)
                """)
        } else {
            logger.error("""
                Failed to release window \(number, privacy: .public) into \
                active space \(active, privacy: .public): error \(result, privacy: .public)
                """)
        }
    }

    /// Shows or hides the private Space (and with it every window inside it).
    public func setVisible(_ visible: Bool) {
        guard isAlive else { return }
        let result: Int32
        if visible {
            result = showSpaces(connection, [spaceID] as CFArray)
        } else {
            guard let hideSpaces else {
                logger.error("SLSHideSpaces unavailable; cannot hide private space")
                return
            }
            result = hideSpaces(connection, [spaceID] as CFArray)
        }
        if result != 0 {
            logger.error("""
                Failed to set private space \(self.spaceID, privacy: .public) \
                visible=\(visible, privacy: .public): error \(result, privacy: .public)
                """)
        }
    }

    /// Hides and destroys the Space. A shown space that outlives the process is a
    /// visible artifact until logout, so this must run before the app exits.
    public func destroy() {
        guard isAlive else { return }
        isAlive = false
        _ = hideSpaces?(connection, [spaceID] as CFArray)
        let result = spaceDestroy?(connection, spaceID) ?? 0
        if result != 0 {
            logger.error("""
                Failed to destroy private space \(self.spaceID, privacy: .public): \
                error \(result, privacy: .public)
                """)
        } else {
            logger.info("Destroyed private space \(self.spaceID, privacy: .public)")
        }
    }

    deinit {
        guard isAlive else { return }
        // `deinit` is nonisolated; the SkyLight calls are plain C and thread-safe enough
        // for teardown, so capture the pointers locally rather than hopping to the main
        // actor (which may never run if the process is exiting).
        _ = hideSpaces?(connection, [spaceID] as CFArray)
        _ = spaceDestroy?(connection, spaceID)
    }
}
