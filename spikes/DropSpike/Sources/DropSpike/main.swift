// DropSpike — feasibility spike for Notch "Drop Zones". Standalone; touches no app code.
// Run:  swift run -c release --package-path spikes/DropSpike DropSpike
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

func log(_ s: String) {
    print("[\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(s)")
    fflush(stdout)
}

// MARK: - Private SkyLight space (copy of NotchKit/.../PrivateSpace.swift, trimmed)

@MainActor final class SkyLightSpace {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias LevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias DestroyFn = @convention(c) (Int32, UInt64) -> Int32

    private let cid: Int32, space: UInt64
    private let add: AddFn, hide: ShowFn?, destroyFn: DestroyFn?

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let pC = dlsym(h, "SLSMainConnectionID"), let pCr = dlsym(h, "SLSSpaceCreate"),
              let pL = dlsym(h, "SLSSpaceSetAbsoluteLevel"), let pS = dlsym(h, "SLSShowSpaces"),
              let pA = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return nil }
        cid = unsafeBitCast(pC, to: ConnFn.self)()
        space = unsafeBitCast(pCr, to: CreateFn.self)(cid, 1, 0)   // middle arg MUST be 1
        guard space != 0 else { return nil }
        let lv = unsafeBitCast(pL, to: LevelFn.self)(cid, space, 400)
        let sh = unsafeBitCast(pS, to: ShowFn.self)(cid, [space] as CFArray)
        add = unsafeBitCast(pA, to: AddFn.self)
        hide = dlsym(h, "SLSHideSpaces").map { unsafeBitCast($0, to: ShowFn.self) }
        destroyFn = dlsym(h, "SLSSpaceDestroy").map { unsafeBitCast($0, to: DestroyFn.self) }
        log("space id=\(space) cid=\(cid) setLevel=\(lv) show=\(sh)")
    }

    func adopt(_ w: NSWindow) {
        let n = w.windowNumber
        guard n > 0 else { return log("adopt skipped, windowNumber=\(n)") }
        log("adopt window \(n) -> space \(space): rc=\(add(cid, space, [n] as CFArray, 7))")
    }

    func destroy() {
        _ = hide?(cid, [space] as CFArray)
        _ = destroyFn?(cid, space)
        log("space destroyed")
    }
}

// MARK: - Drop destination + drag source view

final class ZoneView: NSView, NSDraggingSource {
    let title: String
    private var hot = false
    private var caption = "waiting for a drag"
    private var dragOrigin = NSPoint.zero
    private let promiseQueue = OperationQueue()

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])          // NSDraggingDestination opt-in
        log("\(title): registered types = \(registeredDraggedTypes.map(\.rawValue))")
    }
    required init?(coder: NSCoder) { fatalError() }

    // Non-activating panel never becomes key, so first click must still reach the view.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    private func set(_ c: String, hot: Bool? = nil) {
        caption = c; if let hot { self.hot = hot }; needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        (hot ? NSColor.systemGreen : NSColor.black).withAlphaComponent(hot ? 0.85 : 0.75).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14).fill()
        let at: (String, CGFloat, CGFloat) -> Void = { s, y, size in
            (s as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: NSColor.white])
        }
        at(title, 12, 15)
        at(caption, 36, 11)
        at("drag OUT ⇩ promise", 92, 11)
        at("drag OUT ⇩ plain URL", 112, 11)
    }

    // MARK: NSDraggingDestination
    private func urls(_ s: any NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ s: any NSDraggingInfo) -> NSDragOperation {
        let u = urls(s)
        log("ENTERED \(title) n=\(u.count) src=\(s.draggingSource == nil ? "external" : "self") \(u.map(\.lastPathComponent))")
        set("ENTERED — \(u.count) file(s)", hot: true)
        return .copy
    }
    override func draggingUpdated(_ s: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ s: (any NSDraggingInfo)?) {
        log("EXITED \(title)"); set("exited", hot: false)
    }
    override func prepareForDragOperation(_ s: any NSDraggingInfo) -> Bool {
        log("PREPARE \(title)"); return true
    }
    override func performDragOperation(_ s: any NSDraggingInfo) -> Bool {
        let u = urls(s)
        log("PERFORM \(title) n=\(u.count) formation=\(s.draggingFormation.rawValue) ops=\(s.draggingSourceOperationMask.rawValue)")
        u.forEach { log("   -> \($0.path)") }
        set("DROPPED \(u.count) file(s)", hot: false)
        return !u.isEmpty
    }
    override func concludeDragOperation(_ s: (any NSDraggingInfo)?) { log("CONCLUDE \(title)") }

    // MARK: NSDraggingSource
    override func mouseDown(with e: NSEvent) { dragOrigin = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard p.y > 80, abs(e.locationInWindow.x - dragOrigin.x) + abs(e.locationInWindow.y - dragOrigin.y) > 4 else { return }
        let usePromise = p.y < 106
        let url = Spike.tempFile()
        let writer: any NSPasteboardWriting
        if usePromise {
            let pp = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: PromiseDelegate.shared)
            pp.userInfo = url.path
            writer = pp
        } else {
            writer = url as NSURL
        }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let img = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: img)
        log("BEGIN drag-out mode=\(usePromise ? "filePromise" : "plainURL") key=\(window?.isKeyWindow == true)")
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation {
        ctx == .outsideApplication ? [.copy] : []
    }
    func draggingSession(_ s: NSDraggingSession, willBeginAt p: NSPoint) { log("drag-out willBegin at \(p)") }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation op: NSDragOperation) {
        log("drag-out ENDED op=\(op.rawValue) (\(Spike.opName(op))) at \(p)")
        set("drag-out ended: \(Spike.opName(op))")
    }
}

// MARK: - File promise delegate (nonisolated; runs on its own queue)

final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let shared = PromiseDelegate()
    private let queue: OperationQueue = { let q = OperationQueue(); q.name = "promise"; return q }()

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType t: String) -> String {
        log("promise: fileNameForType \(t) thread=\(Thread.isMainThread ? "main" : "bg")")
        return "NotchStash-\(Int(Date().timeIntervalSince1970)).txt"
    }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let src = (p.userInfo as? String).map(URL.init(fileURLWithPath:))
        log("promise: writePromiseTo \(url.path) thread=\(Thread.isMainThread ? "main" : "bg")")
        do {
            if let src { try FileManager.default.copyItem(at: src, to: url) }
            else { try "promise payload".write(to: url, atomically: true, encoding: .utf8) }
            completionHandler(nil)
        } catch { log("promise: write FAILED \(error)"); completionHandler(error) }
    }
    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { queue }
}

// MARK: - System-wide drag detection (no Accessibility permission)

@MainActor final class DragWatcher {
    private var monitors: [Any] = []
    private var lastCount = NSPasteboard(name: .drag).changeCount
    private var timer: Timer?
    private var active = false

    func start() {
        let m1 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.sample("globalMonitor .leftMouseDragged", e.locationInWindow) }
        }
        let m2 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.end("globalMonitor .leftMouseUp") }
        }
        monitors = [m1, m2].compactMap { $0 }
        log("global monitors installed: \(monitors.count)/2 (trusted=\(AXIsProcessTrusted()))")
        // Fallback poll: proves whether the drag pasteboard alone is enough when the
        // WindowServer starves global mouse events during an active drag session.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample("poll 100ms", NSEvent.mouseLocation) }
        }
    }

    private func sample(_ why: String, _ loc: NSPoint) {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let urls = (pb.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let types = (pb.types ?? []).map(\.rawValue)
        if urls.isEmpty {
            log("DRAG(non-file) via \(why) count=\(pb.changeCount) types=\(types.prefix(6))")
        } else {
            active = true
            log("DRAG START via \(why) count=\(pb.changeCount) n=\(urls.count) at \(NSEvent.mouseLocation) files=\(urls.map(\.lastPathComponent).prefix(4)) types=\(types.prefix(6))")
        }
    }

    private func end(_ why: String) {
        guard active else { return }
        active = false
        log("DRAG END via \(why) at \(NSEvent.mouseLocation)")
    }

    func stop() { monitors.forEach(NSEvent.removeMonitor); timer?.invalidate() }
}

// MARK: - App

@MainActor final class Spike: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    var space: SkyLightSpace?
    var privatePanel: NSPanel?
    var plainPanel: NSPanel?
    let watcher = DragWatcher()
    var statusItem: NSStatusItem?
    var extraPanels: [NSPanel] = []

    static func opName(_ op: NSDragOperation) -> String {
        var n: [String] = []
        if op.contains(.copy) { n.append("copy") }; if op.contains(.move) { n.append("move") }
        if op.contains(.link) { n.append("link") }; if op.isEmpty { n.append("none") }
        return n.joined(separator: "+")
    }

    static func tempFile() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("app.notch/DragStaging")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent("dropspike.txt")
        try? "hello from DropSpike\n".write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func makePanel(_ frame: NSRect, title: String, level: NSWindow.Level) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = level
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true; p.animationBehavior = .none
        p.contentView = ZoneView(title: title)
        p.orderFrontRegardless()
        return p
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let f = screen.frame
        let y = f.maxY - 220
        let statusLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)

        space = SkyLightSpace()
        if ProcessInfo.processInfo.environment["DROPSPIKE_OVERLAP"] != nil {
            // Round 2: private-space panels stacked exactly over normal-space panels.
            // Left pair: A ignores mouse events. Right pair: C does not.
            let left = NSRect(x: f.midX - 410, y: y, width: 400, height: 160)
            let right = NSRect(x: f.midX + 10, y: y, width: 400, height: 160)
            plainPanel = makePanel(left, title: "B · NORMAL (under A)", level: statusLevel)
            privatePanel = makePanel(left, title: "A · PRIVATE ignoresMouse=true", level: statusLevel)
            privatePanel!.ignoresMouseEvents = true
            space?.adopt(privatePanel!)
            let d = makePanel(right, title: "D · NORMAL (under C)", level: statusLevel)
            let c = makePanel(right, title: "C · PRIVATE ignoresMouse=false", level: statusLevel)
            space?.adopt(c)
            extraPanels = [c, d]
            log("OVERLAP layout: A(\(privatePanel!.windowNumber)) over B(\(plainPanel!.windowNumber)); C(\(c.windowNumber)) over D(\(d.windowNumber))")
        } else {
        privatePanel = makePanel(NSRect(x: f.midX - 410, y: y, width: 400, height: 160),
                                 title: "A · PRIVATE SPACE", level: statusLevel)
        space?.adopt(privatePanel!)
        plainPanel = makePanel(NSRect(x: f.midX + 10, y: y, width: 400, height: 160),
                               title: "B · NORMAL SPACE", level: statusLevel)
        }
        log("panels up: private=\(privatePanel!.windowNumber) plain=\(plainPanel!.windowNumber) level=\(statusLevel.rawValue) space=\(space == nil ? "UNAVAILABLE" : "ok")")

        watcher.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⬇︎Spike"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AirDrop temp file", action: #selector(airdrop), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Thumbnail test", action: #selector(thumbnails), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        log("READY — drag files over panel A and panel B; status menu has AirDrop/Thumbnail tests")

        // DROPSPIKE_SELFTEST=1: exercise the headless parts and exit, so the spike can be
        // smoke-tested without a human at the trackpad.
        if ProcessInfo.processInfo.environment["DROPSPIKE_SELFTEST"] == "1" {
            thumbnails()
            if let svc = NSSharingService(named: .sendViaAirDrop) {
                log("AirDrop: service=ok canPerform=\(svc.canPerform(withItems: [Self.tempFile()])) (picker NOT shown in selftest)")
            } else { log("AirDrop: service nil") }
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                MainActor.assumeIsolated { self.quit() }
            }
        }
    }

    @objc func quit() { watcher.stop(); space?.destroy(); NSApp.terminate(nil) }

    // MARK: AirDrop
    @objc func airdrop() {
        let url = Self.tempFile()
        guard let svc = NSSharingService(named: .sendViaAirDrop) else { return log("AirDrop: service nil") }
        svc.delegate = self
        let can = svc.canPerform(withItems: [url])
        log("AirDrop: canPerform=\(can) activationPolicy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive)")
        guard can else { return }
        svc.perform(withItems: [url])
        log("AirDrop: perform() returned; picker visible? (observe)")
    }
    func sharingService(_ s: NSSharingService, didShareItems items: [Any]) {
        log("AirDrop: didShareItems n=\(items.count)")
    }
    func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        log("AirDrop: didFailToShareItems \((error as NSError).domain)/\((error as NSError).code) \(error.localizedDescription)")
    }
    func sharingService(_ s: NSSharingService, sourceWindowForShareItems items: [Any],
                            sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        // NSSharingServiceDelegate is NS_SWIFT_UI_ACTOR, so these are @MainActor already.
        log("AirDrop: asked for source window (scope=\(sharingContentScope.pointee.rawValue))")
        return privatePanel
    }

    // MARK: Thumbnails
    @objc func thumbnails() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("app.notch/DragStaging")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("shot.png")
        let img = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { r in
            NSColor.systemPink.setFill(); r.fill(); return true
        }
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: png) }
        let txt = Self.tempFile()
        for url in [png, txt] {
            let t0 = Date()
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                                   scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if let rep {
                    log("QL \(url.lastPathComponent): type=\(rep.type.rawValue) size=\(rep.nsImage.size) \(ms)ms")
                } else {
                    log("QL \(url.lastPathComponent): FAILED \(err?.localizedDescription ?? "?") \(ms)ms — fallback icon \(NSWorkspace.shared.icon(forFile: url.path).size)")
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = Spike()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
