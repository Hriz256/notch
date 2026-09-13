import CoreGraphics
import Foundation
import os

/// The real `BrightnessSource`: the private `DisplayServices.framework`, resolved with
/// `dlsym` at runtime so a missing symbol degrades to "no brightness HUD" instead of a
/// link failure. Signatures verified by spike on macOS 26.5 (plan Task 8).
@MainActor
public final class DisplayServicesBrightnessSource: BrightnessSource {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, CFNotificationCallback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?) -> Int32

    private struct Functions {
        let get: GetBrightness
        let canChange: CanChange
        let register: Register
        let unregister: Unregister?
    }

    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let logger = Logger(subsystem: "app.notch", category: "hud.brightness")

    /// The one live source the C callback forwards to. A C function pointer cannot capture,
    /// so the route from the callback to the handler is this static.
    private static weak var current: DisplayServicesBrightnessSource?

    private let functions: Functions?
    private let display: CGDirectDisplayID?
    private var handler: (@MainActor () -> Void)?

    public init() {
        functions = Self.loadFunctions()
        display = Self.builtinDisplay()
    }

    public var isAvailable: Bool {
        guard let functions, let display else { return false }
        return functions.canChange(display)
    }

    public func brightness() -> Double? {
        guard let functions, let display else { return nil }
        var value: Float = 0
        guard functions.get(display, &value) == 0 else { return nil }
        return Double(value)
    }

    public func observe(_ handler: @escaping @MainActor () -> Void) -> Bool {
        guard let functions, let display else { return false }
        self.handler = handler
        Self.current = self
        let status = functions.register(display, nil, Self.callback)
        guard status == 0 else {
            Self.logger.error("DisplayServicesRegisterForBrightnessChangeNotifications failed: \(status, privacy: .public)")
            self.handler = nil
            return false
        }
        return true
    }

    public func stopObserving() {
        handler = nil
        if let functions, let display, let unregister = functions.unregister {
            _ = unregister(display, nil)
        }
        if Self.current === self { Self.current = nil }
    }

    // MARK: - Private

    /// Fires on CoreBrightness's own XPC queue, *not* on the thread that registered: a
    /// `MainActor.assumeIsolated` straight out of the callback traps (`_dispatch_assert_queue_fail`,
    /// one brightness key press away). So it hops to the main queue first, and everything
    /// main-actor — the static and the handler — is touched only inside that block.
    private static let callback: CFNotificationCallback = { _, _, _, _, _ in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DisplayServicesBrightnessSource.current?.handler?()
            }
        }
    }

    private static func loadFunctions() -> Functions? {
        guard let handle = dlopen(path, RTLD_NOW) else {
            logger.info("DisplayServices.framework did not load")
            return nil
        }
        guard let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness"),
              let register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications")
        else {
            logger.info("DisplayServices brightness symbols missing")
            return nil
        }
        let unregister = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications")
        return Functions(
            get: unsafeBitCast(get, to: GetBrightness.self),
            canChange: unsafeBitCast(canChange, to: CanChange.self),
            register: unsafeBitCast(register, to: Register.self),
            unregister: unregister.map { unsafeBitCast($0, to: Unregister.self) }
        )
    }

    private static func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
