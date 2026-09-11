import AppKit

/// Tracks whether the mouse is inside a screen rect using global + local mouse-moved monitors.
/// Global mouse-moved monitoring needs no Accessibility permission.
@MainActor
public final class HoverMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isInside = false
    private let rectProvider: () -> CGRect
    private let onChange: (Bool) -> Void

    public init(rectProvider: @escaping () -> CGRect, onChange: @escaping (Bool) -> Void) {
        self.rectProvider = rectProvider
        self.onChange = onChange
    }

    public func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.evaluate() }
            return event
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func evaluate() {
        let inside = rectProvider().contains(NSEvent.mouseLocation)
        guard inside != isInside else { return }
        isInside = inside
        onChange(inside)
    }
}
