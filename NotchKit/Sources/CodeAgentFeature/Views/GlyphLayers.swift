import AppKit
import QuartzCore
import SwiftUI

/// The four working glyphs, drawn by Core Animation instead of by a per-frame SwiftUI body.
///
/// **Why this file exists.** ``ActivityGlyph``'s editing, reading, running and waiting marks
/// each used to wrap their body in `TimelineView(.animation)` and derive sway, trim and blink
/// from `context.date`. A timeline re-runs its body on *every displayed frame* — 120 Hz on
/// this hardware — for as long as the glyph is on screen, and these glyphs are on screen for
/// essentially the whole of a working session, in the peek slot *and* again in the expanded
/// header. Measured: Notch sat at 5–6 % CPU while an agent worked, against ~1 % at rest.
///
/// Every one of the four is expressible as a repeating animation on an animatable layer
/// property, which the render server is handed once and which costs the app nothing per frame
/// after that. ``ThinkingDots`` has always worked that way; these now do too.
///
/// **What is traded away.** A repeating animation restarts when the view hosting it is
/// re-created, where a function of wall-clock time is continuous however often the island
/// re-renders. Each glyph is given an identity of its own (`.id` on ``LoopingGlyph``) so the
/// model's churn cannot restart it, but a *stage change* still starts the new glyph's cycle
/// from the beginning. Accepted by the owner; see the animation audit, A11.

// MARK: - Which glyph

/// The four kinds that loop. The other four marks are not here: ``ActivityKind/thinking`` is
/// ``ThinkingDots`` (already Core Animation), ``ActivityKind/completed`` and
/// ``ActivityKind/failed`` play once and stop, and ``ActivityKind/idle`` draws nothing.
enum GlyphLayerKind: String, Hashable, Sendable, CaseIterable {
    case editing
    case reading
    case running
    case waiting
}

// MARK: - The loop, as a value

/// One repeating loop, in the shape Core Animation wants it.
///
/// Pure, so the periods can be checked against the `GlyphMotion` functions the timelines used
/// to call without a view, a window or a run loop.
struct GlyphLoop: Equatable, Sendable {
    /// The whole cycle in seconds: one there-and-back for a wave, one ramp otherwise. This is
    /// the number the old `GlyphMotion.phase(_:period:)` took.
    let period: Double
    /// A wave — out and back on the same easing — rather than a ramp that snaps to its start.
    let autoreverses: Bool

    /// What `CAAnimation.duration` gets. Half the period for a wave, because Core Animation
    /// plays the return leg itself and charges the same duration for it.
    var duration: Double { autoreverses ? period / 2 : period }

    /// Where in the cycle the loop begins.
    ///
    /// `GlyphMotion.wave` starts at rest and moving: `sin(0) == 0`. A `from`/`to` autoreverse
    /// starts at one extreme instead, so a wave is nudged half its forward leg in and picks
    /// the cycle up in the middle, where the timeline version began. A ramp already starts
    /// where `phase` does.
    var timeOffset: Double { autoreverses ? duration / 2 : 0 }
}

// MARK: - Every number the four glyphs are drawn from

/// The geometry and the periods of the looping glyphs, in one table.
///
/// They used to be `private static let`s inside four `TimelineView` bodies, which is why none
/// of them was ever under test. Nothing here changed value in the move to Core Animation — the
/// tests in `CodeAgentFeatureTests` pin every one of them.
enum GlyphSpec {
    /// The gap between a glyph's symbol and the rule under it. Both stacked glyphs use it.
    static let rowSpacing: CGFloat = 1.5
    /// Every glyph's symbol is drawn at this fraction of the type size, semibold.
    static let symbolScale: CGFloat = 0.85

    /// A tilted pencil sliding back and forth over a salmon underline that writes itself.
    enum Editing {
        /// The sway: ±3 pt, a full there-and-back every 0.9 s.
        static let sway = GlyphLoop(period: 0.9, autoreverses: true)
        static let swayDistance: CGFloat = 3
        /// The tilt a hand holds a pencil at, in SwiftUI's degrees (positive is clockwise).
        static let tilt: Double = -25

        /// The write: the underline grows from nothing to its full width every 1.4 s.
        static let write = GlyphLoop(period: 1.4, autoreverses: false)
        /// The last quarter of the write loop is the fade, so the line never snaps away.
        static let fadeStart: Double = 0.75
        static let underlineHeight: CGFloat = 1.5
        static func underlineWidth(size: CGFloat) -> CGFloat { size * 1.2 }

        /// How opaque the underline is `written` of the way through a write loop.
        ///
        /// The formula the timeline evaluated per frame, kept as the definition the keyframe
        /// below is checked against.
        static func underlineOpacity(written: Double) -> Double {
            written < fadeStart ? 1 : 1 - (written - fadeStart) / (1 - fadeStart)
        }

        /// ``underlineOpacity(written:)`` as a `CAKeyframeAnimation`'s values and key times.
        /// Linear between the stops, which is what the formula is on either side of
        /// ``fadeStart``.
        static var underlineFade: (values: [Double], keyTimes: [Double]) {
            ([1, 1, 0], [0, fadeStart, 1])
        }
    }

    /// A magnifier scanning left and right along a faint line.
    enum Reading {
        static let scan = GlyphLoop(period: 1.2, autoreverses: true)
        static let travel: CGFloat = 4
        static let lineHeight: CGFloat = 1
        static let lineOpacity: CGFloat = 0.25
        static func lineWidth(size: CGFloat) -> CGFloat { size * 1.2 }
    }

    /// A terminal window typing a line, with a blinking cursor after it.
    enum Running {
        /// The line types itself out over 1.2 s and starts again.
        static let type = GlyphLoop(period: 1.2, autoreverses: false)
        /// The cursor is on for the first half of every 0.5 s and off for the second.
        static let blink = GlyphLoop(period: 0.5, autoreverses: false)
        /// A hard step, not a fade: `.discrete` wants one more key time than it has values.
        static var blinkOpacity: (values: [Double], keyTimes: [Double]) {
            ([1, 0], [0, 0.5, 1])
        }

        /// The 14 × 10 frame of the spec, expressed against the type size so the glyph still
        /// fits when the header renders it a point smaller than the compact slot does.
        static func frameWidth(size: CGFloat) -> CGFloat { size * 1.08 }
        static func frameHeight(size: CGFloat) -> CGFloat { size * 0.77 }
        static func cursorHeight(size: CGFloat) -> CGFloat { frameHeight(size: size) * 0.6 }
        /// Sized so prompt, line and cursor still clear the right-hand stroke when the line
        /// is fully typed.
        static func lineWidth(size: CGFloat) -> CGFloat { frameWidth(size: size) * 0.3 }
        /// The prompt's type size, against the window's height.
        static func promptSize(size: CGFloat) -> CGFloat { frameHeight(size: size) * 0.62 }

        static let cornerRadius: CGFloat = 2
        static let stroke: CGFloat = 1
        static let lineHeight: CGFloat = 1
        static let cursorWidth: CGFloat = 1
        /// The `HStack`'s spacing and its leading pad, inside the window.
        static let itemSpacing: CGFloat = 1
        static let leadingPad: CGFloat = 1.5
    }

    /// A raised hand waving from the wrist.
    enum Waiting {
        static let wave = GlyphLoop(period: 0.8, autoreverses: true)
        /// Degrees either side of upright, in SwiftUI's sense.
        static let tilt: Double = 12
    }
}

// MARK: - SwiftUI's half

/// One of the four working glyphs, hosted as a layer tree.
///
/// Sized to the same box every glyph shares, so swapping kinds still never shifts the text
/// beside it, and nothing is clipped: the pencil's sway and the terminal's stroke both sit a
/// little outside that box, exactly as they did under SwiftUI.
struct LoopingGlyph: View {
    let kind: GlyphLayerKind
    let size: CGFloat

    var body: some View {
        GlyphLayerRepresentable(
            kind: kind,
            size: size,
            // Answered here as well as in ``ActivityGlyph`` so no caller can start the loops
            // behind Reduce Motion's back — the rule ``ThinkingDots`` already follows. The
            // value is live: `GlyphMotion.isReduced` observes the setting.
            animates: !GlyphMotion.isReduced
        )
        .frame(
            width: ActivityGlyph.boxWidth(for: size),
            height: ActivityGlyph.boxHeight(for: size)
        )
    }
}

/// The bridge. Deliberately value-typed with no closures in it, so SwiftUI can compare it and
/// so the layer tree is built from the kind rather than captured from a body.
struct GlyphLayerRepresentable: NSViewRepresentable {
    let kind: GlyphLayerKind
    let size: CGFloat
    let animates: Bool

    func makeNSView(context: Context) -> GlyphLayerView {
        GlyphLayerView(kind: kind, size: size, animates: animates)
    }

    /// The artwork never changes — only whether it is allowed to move. A live Reduce Motion
    /// toggle therefore stops the loops without rebuilding a layer.
    func updateNSView(_ nsView: GlyphLayerView, context: Context) {
        nsView.animates = animates
    }
}

// MARK: - AppKit's half

/// A layer tree built once, and repeating animations attached only while the view is in a
/// window and motion is allowed.
///
/// The window rule is the point of the class as much as the animations are: a layer whose view
/// has left its window still burns CPU with an animation attached, so leaving a window strips
/// them outright rather than trusting anything downstream to stop drawing.
final class GlyphLayerView: NSView {
    /// Every loop this glyph owns, and where it goes. Built once, in `init`.
    private let bindings: [GlyphLoopBinding]
    private let boxSize: CGSize

    /// Whether the loops may run at all. Written by `updateNSView`.
    var animates: Bool {
        didSet {
            guard animates != oldValue else { return }
            refreshLoops()
        }
    }

    init(kind: GlyphLayerKind, size: CGFloat, animates: Bool) {
        self.animates = animates
        boxSize = CGSize(
            width: ActivityGlyph.boxWidth(for: size),
            height: ActivityGlyph.boxHeight(for: size)
        )
        let built = GlyphLayerBuilder.build(kind: kind, size: size, box: boxSize)
        bindings = built.bindings
        super.init(frame: CGRect(origin: .zero, size: boxSize))

        wantsLayer = true
        layer?.masksToBounds = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in built.layers { layer?.addSublayer(sublayer) }
        CATransaction.commit()
        applyContentsScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GlyphLayerView is built in code, never from a nib")
    }

    override var intrinsicContentSize: NSSize { boxSize }

    /// The whole off-screen rule. Called when the view joins a window *and* when it leaves
    /// one, which is the only signal that matters here: SwiftUI tears the glyph out of the
    /// hierarchy the moment the card stops being presented.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContentsScale()
        refreshLoops()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyContentsScale()
    }

    /// How many loops are actually attached. For the tests, which have no window to put the
    /// view in and so can only assert the negative half of the rule directly.
    var attachedLoopCount: Int {
        bindings.count { $0.layer.animation(forKey: $0.key) != nil }
    }

    private func refreshLoops() {
        let running = animates && window != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for binding in bindings {
            if running {
                binding.layer.add(binding.animation, forKey: binding.key)
            } else {
                binding.layer.removeAnimation(forKey: binding.key)
            }
        }
        CATransaction.commit()
    }

    /// Layers made by hand default to a scale of 1 and would draw soft on a Retina display.
    private func applyContentsScale() {
        guard let layer else { return }
        Self.apply(scale: window?.backingScaleFactor ?? 2, to: layer)
    }

    private static func apply(scale: CGFloat, to layer: CALayer) {
        layer.contentsScale = scale
        layer.sublayers?.forEach { apply(scale: scale, to: $0) }
    }
}

/// One repeating animation and the layer it belongs to.
struct GlyphLoopBinding {
    let layer: CALayer
    let key: String
    let animation: CAAnimation
}

// MARK: - Building the layer trees

/// Lays each glyph out in the box ``ActivityGlyph`` gives it, in AppKit's y-up coordinates.
///
/// Every position below is the arithmetic the `VStack`/`HStack` it replaces was doing: stated
/// here rather than inferred, because a layer has no layout system to ask.
enum GlyphLayerBuilder {
    static func build(
        kind: GlyphLayerKind,
        size: CGFloat,
        box: CGSize
    ) -> (layers: [CALayer], bindings: [GlyphLoopBinding]) {
        switch kind {
        case .editing: editing(size: size, box: box)
        case .reading: reading(size: size, box: box)
        case .running: running(size: size, box: box)
        case .waiting: waiting(size: size, box: box)
        }
    }

    // MARK: Editing

    /// `VStack(spacing: 1.5) { pencil (size tall); underline (1.5 tall) }` — which is exactly
    /// the box's height, so there is no centring offset: the underline sits on the bottom edge.
    private static func editing(
        size: CGFloat,
        box: CGSize
    ) -> (layers: [CALayer], bindings: [GlyphLoopBinding]) {
        var layers: [CALayer] = []
        var bindings: [GlyphLoopBinding] = []

        let underlineWidth = GlyphSpec.Editing.underlineWidth(size: size)
        let pencilCentreY = GlyphSpec.Editing.underlineHeight + GlyphSpec.rowSpacing + size / 2

        if let image = symbolImage(
            "pencil",
            pointSize: size * GlyphSpec.symbolScale,
            weight: .semibold,
            color: .white
        ) {
            let pencil = imageLayer(image)
            pencil.position = CGPoint(x: box.width / 2, y: pencilCentreY)
            pencil.transform = CATransform3DMakeRotation(
                layerRadians(degrees: GlyphSpec.Editing.tilt), 0, 0, 1
            )
            layers.append(pencil)
            bindings.append(
                GlyphLoopBinding(
                    layer: pencil,
                    key: "sway",
                    // The sway rides on `position`, not on the transform, so it composes with
                    // the tilt the same way SwiftUI's `.offset` after `.rotationEffect` did.
                    animation: waveAnimation(
                        keyPath: "position.x",
                        centre: box.width / 2,
                        amplitude: GlyphSpec.Editing.swayDistance,
                        loop: GlyphSpec.Editing.sway
                    )
                )
            )
        }

        // Left-anchored, so growing the bounds writes the line rightwards.
        let underline = CALayer()
        underline.anchorPoint = CGPoint(x: 0, y: 0.5)
        underline.bounds = CGRect(
            x: 0, y: 0, width: underlineWidth, height: GlyphSpec.Editing.underlineHeight
        )
        underline.position = CGPoint(
            x: (box.width - underlineWidth) / 2, y: GlyphSpec.Editing.underlineHeight / 2
        )
        underline.cornerRadius = GlyphSpec.Editing.underlineHeight / 2
        underline.backgroundColor = CodePalette.salmonInk.cgColor
        layers.append(underline)

        bindings.append(
            GlyphLoopBinding(
                layer: underline,
                key: "write",
                animation: rampAnimation(
                    keyPath: "bounds.size.width",
                    from: 0,
                    to: underlineWidth,
                    loop: GlyphSpec.Editing.write
                )
            )
        )
        let fade = GlyphSpec.Editing.underlineFade
        bindings.append(
            GlyphLoopBinding(
                layer: underline,
                key: "fade",
                animation: keyframeAnimation(
                    keyPath: "opacity",
                    values: fade.values,
                    keyTimes: fade.keyTimes,
                    mode: .linear,
                    loop: GlyphSpec.Editing.write
                )
            )
        )

        return (layers, bindings)
    }

    // MARK: Reading

    /// `VStack(spacing: 1.5) { magnifier (size tall); line (1 tall) }` — 2.5 pt short of the
    /// box, so the stack sits a quarter of a point up from the bottom edge.
    private static func reading(
        size: CGFloat,
        box: CGSize
    ) -> (layers: [CALayer], bindings: [GlyphLoopBinding]) {
        var layers: [CALayer] = []
        var bindings: [GlyphLoopBinding] = []

        let lineWidth = GlyphSpec.Reading.lineWidth(size: size)
        let stackHeight = size + GlyphSpec.rowSpacing + GlyphSpec.Reading.lineHeight
        let bottom = (box.height - stackHeight) / 2

        if let image = symbolImage(
            "magnifyingglass",
            pointSize: size * GlyphSpec.symbolScale,
            weight: .semibold,
            color: .white
        ) {
            let glass = imageLayer(image)
            glass.position = CGPoint(
                x: box.width / 2,
                y: bottom + GlyphSpec.Reading.lineHeight + GlyphSpec.rowSpacing + size / 2
            )
            layers.append(glass)
            bindings.append(
                GlyphLoopBinding(
                    layer: glass,
                    key: "scan",
                    animation: waveAnimation(
                        keyPath: "position.x",
                        centre: box.width / 2,
                        amplitude: GlyphSpec.Reading.travel,
                        loop: GlyphSpec.Reading.scan
                    )
                )
            )
        }

        let line = CALayer()
        line.bounds = CGRect(x: 0, y: 0, width: lineWidth, height: GlyphSpec.Reading.lineHeight)
        line.position = CGPoint(x: box.width / 2, y: bottom + GlyphSpec.Reading.lineHeight / 2)
        line.cornerRadius = GlyphSpec.Reading.lineHeight / 2
        line.backgroundColor = white(GlyphSpec.Reading.lineOpacity)
        layers.append(line)

        return (layers, bindings)
    }

    // MARK: Running

    /// The window, centred in the box, with the prompt, the typed line and the cursor packed
    /// from its left edge — the `HStack(spacing: 1)` inside a `.padding(.leading, 1.5)`.
    private static func running(
        size: CGFloat,
        box: CGSize
    ) -> (layers: [CALayer], bindings: [GlyphLoopBinding]) {
        var layers: [CALayer] = []
        var bindings: [GlyphLoopBinding] = []

        let frameWidth = GlyphSpec.Running.frameWidth(size: size)
        let frameHeight = GlyphSpec.Running.frameHeight(size: size)
        let originX = (box.width - frameWidth) / 2
        // The `HStack` is centred in the window whatever its own height, and every child is
        // centred on it, so one line serves all three.
        let midY = box.height / 2

        // A layer's border draws *inside* its bounds where SwiftUI's `.stroke` straddles the
        // shape's edge, so the layer is one point larger in each direction and its radius half
        // a point larger: the rectangle that ends up on screen is the same one.
        let window = CALayer()
        window.bounds = CGRect(
            x: 0,
            y: 0,
            width: frameWidth + GlyphSpec.Running.stroke,
            height: frameHeight + GlyphSpec.Running.stroke
        )
        window.position = CGPoint(x: box.width / 2, y: midY)
        window.borderWidth = GlyphSpec.Running.stroke
        window.borderColor = white(1)
        window.cornerRadius = GlyphSpec.Running.cornerRadius + GlyphSpec.Running.stroke / 2
        window.cornerCurve = .continuous
        layers.append(window)

        // The prompt is drawn to an image rather than hosted in a `CATextLayer`: a text layer
        // has to be told about the view's flippedness to come out the right way up, and one
        // ">" is cheaper to draw once than to re-lay-out.
        let promptFont = NSFont.monospacedSystemFont(
            ofSize: GlyphSpec.Running.promptSize(size: size), weight: .bold
        )
        let promptImage = textImage(">", font: promptFont, color: .white)
        let prompt = imageLayer(promptImage)
        let promptX = originX + GlyphSpec.Running.leadingPad
        prompt.position = CGPoint(x: promptX + promptImage.size.width / 2, y: midY)
        layers.append(prompt)

        let lineX = promptX + promptImage.size.width + GlyphSpec.Running.itemSpacing
        let lineWidth = GlyphSpec.Running.lineWidth(size: size)

        let line = CALayer()
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.bounds = CGRect(x: 0, y: 0, width: lineWidth, height: GlyphSpec.Running.lineHeight)
        line.position = CGPoint(x: lineX, y: midY)
        line.cornerRadius = GlyphSpec.Running.lineHeight / 2
        line.backgroundColor = white(1)
        layers.append(line)
        bindings.append(
            GlyphLoopBinding(
                layer: line,
                key: "type",
                animation: rampAnimation(
                    keyPath: "bounds.size.width", from: 0, to: lineWidth,
                    loop: GlyphSpec.Running.type
                )
            )
        )

        // The cursor sat *after* the line in an `HStack`, so it was pushed along by the line's
        // width: here it rides the same ramp on its own position, in lockstep.
        let cursorX = lineX + GlyphSpec.Running.itemSpacing
        let cursor = CALayer()
        cursor.anchorPoint = CGPoint(x: 0, y: 0.5)
        cursor.bounds = CGRect(
            x: 0, y: 0,
            width: GlyphSpec.Running.cursorWidth,
            height: GlyphSpec.Running.cursorHeight(size: size)
        )
        cursor.position = CGPoint(x: cursorX + lineWidth, y: midY)
        cursor.backgroundColor = white(1)
        layers.append(cursor)
        bindings.append(
            GlyphLoopBinding(
                layer: cursor,
                key: "type",
                animation: rampAnimation(
                    keyPath: "position.x", from: cursorX, to: cursorX + lineWidth,
                    loop: GlyphSpec.Running.type
                )
            )
        )
        let blink = GlyphSpec.Running.blinkOpacity
        bindings.append(
            GlyphLoopBinding(
                layer: cursor,
                key: "blink",
                animation: keyframeAnimation(
                    keyPath: "opacity",
                    values: blink.values,
                    keyTimes: blink.keyTimes,
                    mode: .discrete,
                    loop: GlyphSpec.Running.blink
                )
            )
        )

        return (layers, bindings)
    }

    // MARK: Waiting

    /// The hand at its natural size, centred in the box, turning about its wrist.
    private static func waiting(
        size: CGFloat,
        box: CGSize
    ) -> (layers: [CALayer], bindings: [GlyphLoopBinding]) {
        guard let image = symbolImage(
            "hand.raised.fill",
            pointSize: size * GlyphSpec.symbolScale,
            weight: .semibold,
            color: CodePalette.amberInk.nsColor
        ) else { return ([], []) }

        let hand = imageLayer(image)
        // From the wrist, not the middle of the palm: turning about the centre reads as a
        // spin rather than as a wave. `.bottom` in SwiftUI is `(0.5, 0)` in a y-up layer.
        hand.anchorPoint = CGPoint(x: 0.5, y: 0)
        hand.position = CGPoint(x: box.width / 2, y: (box.height - image.size.height) / 2)

        let bind = GlyphLoopBinding(
            layer: hand,
            key: "wave",
            animation: waveAnimation(
                keyPath: "transform.rotation.z",
                centre: 0,
                amplitude: abs(layerRadians(degrees: GlyphSpec.Waiting.tilt)),
                loop: GlyphSpec.Waiting.wave
            )
        )
        return ([hand], [bind])
    }
}

// MARK: - The animations

extension GlyphLayerBuilder {
    /// A there-and-back on one property: `centre ± amplitude`, reversed rather than restarted.
    ///
    /// `GlyphMotion.wave` is a sine. An autoreversing `easeInEaseOut` is the cubic that stands
    /// in for it — the same substitution ``ThinkingDots`` has always made, and at 3 and 4 pt of
    /// travel the two differ by a fraction of a point at their widest.
    static func waveAnimation(
        keyPath: String,
        centre: CGFloat,
        amplitude: CGFloat,
        loop: GlyphLoop
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = centre - amplitude
        animation.toValue = centre + amplitude
        animation.duration = loop.duration
        animation.timeOffset = loop.timeOffset
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// `0 → 1`, restarting every period: the linear ramp `GlyphMotion.phase` handed out.
    static func rampAnimation(
        keyPath: String,
        from: CGFloat,
        to: CGFloat,
        loop: GlyphLoop
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = loop.duration
        animation.timeOffset = loop.timeOffset
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func keyframeAnimation(
        keyPath: String,
        values: [Double],
        keyTimes: [Double],
        mode: CAAnimationCalculationMode,
        loop: GlyphLoop
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        animation.calculationMode = mode
        animation.duration = loop.duration
        animation.timeOffset = loop.timeOffset
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

// MARK: - Drawing helpers

extension GlyphLayerBuilder {
    /// SwiftUI's positive degrees turn clockwise; a macOS layer's turn the other way.
    static func layerRadians(degrees: Double) -> CGFloat { CGFloat(-degrees * .pi / 180) }

    static func white(_ opacity: CGFloat) -> CGColor {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: opacity).cgColor
    }

    /// An SF symbol at the size and weight `.font(.system(size:weight:))` would have given it,
    /// tinted, since a layer has no foreground style to inherit.
    static func symbolImage(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize, weight: weight, scale: .medium
        )
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    static func textImage(_ string: String, font: NSFont, color: NSColor) -> NSImage {
        let text = NSAttributedString(
            string: string, attributes: [.font: font, .foregroundColor: color]
        )
        let measured = text.size()
        let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        return NSImage(size: size, flipped: true) { rect in
            text.draw(in: rect)
            return true
        }
    }

    /// A layer that is nothing but the image, at the image's own size.
    static func imageLayer(_ image: NSImage) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.bounds = CGRect(origin: .zero, size: image.size)
        layer.contentsGravity = .resizeAspect
        return layer
    }
}
