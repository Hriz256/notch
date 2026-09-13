import Foundation
import HUDShared
import os

/// What the monitor needs from DisplayServices, behind a protocol so tests use a fake.
@MainActor
public protocol BrightnessSource: AnyObject {
    /// The framework loaded and there is an adjustable built-in display.
    var isAvailable: Bool { get }
    func brightness() -> Double?
    /// Calls `handler` on the main actor on every change. `false` if registration failed.
    func observe(_ handler: @escaping @MainActor () -> Void) -> Bool
    func stopObserving()
}

/// Reports the built-in display's brightness (spec §2 "Brightness source").
///
/// `onReading`'s second argument is `initial`: the level at start, which the view model
/// records as a baseline and never shows.
@MainActor
public final class BrightnessMonitor {
    public var onReading: (HUDReading, Bool) -> Void = { _, _ in }

    private let source: any BrightnessSource
    private let logger = Logger(subsystem: "app.notch", category: "hud.brightness")
    private var isObserving = false
    private var isStopped = false

    public init(source: any BrightnessSource) {
        self.source = source
    }

    /// Idempotent: a second `start()` without a `stop()` is a no-op, so the real source never
    /// registers twice for the same display (which would double every later change).
    public func start() {
        guard !isObserving else { return }
        isStopped = false
        guard source.isAvailable else {
            logger.info("brightness unavailable: DisplayServices missing or no adjustable built-in display")
            return
        }
        guard source.observe({ [weak self] in self?.changed() }) else {
            logger.info("brightness change notifications could not be registered")
            return
        }
        isObserving = true
        if let level = source.brightness() {
            onReading(HUDReading(kind: .brightness, level: level), true)
        }
    }

    public func stop() {
        isStopped = true
        if isObserving { source.stopObserving() }
        isObserving = false
    }

    // MARK: - Private

    private func changed() {
        guard !isStopped, isObserving, let level = source.brightness() else { return }
        onReading(HUDReading(kind: .brightness, level: level), false)
    }
}
