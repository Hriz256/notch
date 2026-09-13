import AppKit
import Observation

/// The live value of the system's *Reduce Motion* setting.
///
/// The island used to sample `accessibilityDisplayShouldReduceMotion` once, when the
/// surface window was built, and again only on a screen reconfiguration — so turning
/// Reduce Motion on while Notch was running changed nothing about how the island moved
/// until a display changed. The feature views read the setting fresh on every draw, which
/// left the app internally inconsistent about it as well.
///
/// This is `@Observable`, so a view that reads ``isReduced`` while building its body is
/// re-drawn the moment the setting changes, and the value is refreshed from one workspace
/// notification rather than polled. Nothing runs between changes.
@MainActor
@Observable
public final class MotionSettings {
    /// The app-wide instance. Lives for the process, so its observer is never removed.
    public static let shared = MotionSettings()

    public private(set) var isReduced: Bool

    @ObservationIgnored private let read: @MainActor () -> Bool
    @ObservationIgnored private let centre: NotificationCenter
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - read: where the current value comes from. Injectable for tests; in the app it
    ///     is the workspace's own flag.
    ///   - centre: the notification centre that announces accessibility changes.
    public init(
        read: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        centre: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.read = read
        self.centre = centre
        self.isReduced = read()
        // `queue: nil` — delivered synchronously on the posting thread, which for this
        // notification is the main one. The thread is checked rather than assumed, the
        // way ``ScrollSwipeMonitor`` checks it: `assumeIsolated` traps when it is wrong.
        observer = centre.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// Re-reads the setting. Writes only on a real change, so a display-options
    /// notification about something else (contrast, transparency) costs nothing and
    /// re-draws nothing.
    func refresh() {
        let now = read()
        guard now != isReduced else { return }
        isReduced = now
    }

    /// Stops observing. The shared instance never needs this; instances made by tests do.
    public func stop() {
        if let observer { centre.removeObserver(observer) }
        observer = nil
    }
}
