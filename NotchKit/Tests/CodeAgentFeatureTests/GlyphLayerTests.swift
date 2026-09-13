import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import Testing

@testable import CodeAgentFeature

/// The four working glyphs moved off `TimelineView(.animation)` and onto Core Animation.
///
/// Nothing about how they *look* was supposed to change, so this suite is mostly a set of
/// pins: the periods, the amplitudes and the geometry are held at the values the timeline
/// bodies used, and the Core Animation parameters are held against the `GlyphMotion`
/// functions that define what each loop is.
@Suite("Code glyph loops on Core Animation")
@MainActor
struct GlyphLayerTests {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: The loop, as a value

    @Test("A wave costs Core Animation half its period, because it plays the return leg itself")
    func waveLoopDuration() {
        let wave = GlyphLoop(period: 0.9, autoreverses: true)
        #expect(wave.duration == 0.45)
        // `GlyphMotion.wave` starts at rest and moving; a from/to autoreverse starts at an
        // extreme, so the loop is nudged half its forward leg in to begin where the sine did.
        #expect(wave.timeOffset == 0.225)

        let ramp = GlyphLoop(period: 1.4, autoreverses: false)
        #expect(ramp.duration == 1.4)
        #expect(ramp.timeOffset == 0)
    }

    @Test("Every wave's full cycle is still the period GlyphMotion.wave used")
    func wavePeriodsMatchTheSine() {
        for loop in [GlyphSpec.Editing.sway, GlyphSpec.Reading.scan, GlyphSpec.Waiting.wave] {
            #expect(loop.autoreverses)
            // Core Animation's duration is the forward leg; two of them is one whole cycle,
            // which is where the sine comes back to rest.
            #expect(abs(loop.duration * 2 - loop.period) < 1e-12)
            let backAtRest = Self.epoch.addingTimeInterval(loop.duration)
            #expect(abs(GlyphMotion.wave(backAtRest, period: loop.period)) < 1e-9)
            // The extreme the `from`/`to` pair stands at is the sine's peak, a quarter in.
            let peak = Self.epoch.addingTimeInterval(loop.duration / 2)
            #expect(abs(GlyphMotion.wave(peak, period: loop.period) - 1) < 1e-9)
        }
    }

    @Test("Every ramp restarts on its period, the way GlyphMotion.phase did")
    func rampPeriodsMatchThePhase() {
        for loop in [GlyphSpec.Editing.write, GlyphSpec.Running.type, GlyphSpec.Running.blink] {
            #expect(!loop.autoreverses)
            #expect(loop.duration == loop.period)
            #expect(GlyphMotion.phase(Self.epoch.addingTimeInterval(loop.period), period: loop.period) == 0)
        }
    }

    // MARK: The table the timelines used to hide

    @Test("The periods and amplitudes are the ones the timeline glyphs had")
    func periodsAreUnchanged() {
        #expect(GlyphSpec.Editing.sway.period == 0.9)
        #expect(GlyphSpec.Editing.swayDistance == 3)
        #expect(GlyphSpec.Editing.tilt == -25)
        #expect(GlyphSpec.Editing.write.period == 1.4)
        #expect(GlyphSpec.Editing.fadeStart == 0.75)

        #expect(GlyphSpec.Reading.scan.period == 1.2)
        #expect(GlyphSpec.Reading.travel == 4)
        #expect(GlyphSpec.Reading.lineOpacity == 0.25)

        #expect(GlyphSpec.Running.type.period == 1.2)
        #expect(GlyphSpec.Running.blink.period == 0.5)

        #expect(GlyphSpec.Waiting.wave.period == 0.8)
        #expect(GlyphSpec.Waiting.tilt == 12)

        #expect(GlyphSpec.symbolScale == 0.85)
        #expect(GlyphSpec.rowSpacing == 1.5)
    }

    /// 14 × 10 at the compact slot's 13 pt, which is the frame the spec asks for.
    @Test("The terminal window is still the spec's 14 x 10 frame")
    func runningGeometry() {
        #expect(abs(GlyphSpec.Running.frameWidth(size: 13) - 14.04) < 1e-9)
        #expect(abs(GlyphSpec.Running.frameHeight(size: 13) - 10.01) < 1e-9)
        #expect(abs(GlyphSpec.Running.cursorHeight(size: 13) - 10.01 * 0.6) < 1e-9)
        #expect(abs(GlyphSpec.Running.lineWidth(size: 13) - 14.04 * 0.3) < 1e-9)
        #expect(abs(GlyphSpec.Running.promptSize(size: 13) - 10.01 * 0.62) < 1e-9)
        // The header draws the same glyph a point smaller and it still has to fit.
        #expect(GlyphSpec.Running.frameWidth(size: 12) < ActivityGlyph.boxWidth(for: 12))
        #expect(GlyphSpec.Running.frameHeight(size: 12) < ActivityGlyph.boxHeight(for: 12))
    }

    @Test("Both rules are 1.2 x the type size, as they were")
    func ruleWidths() {
        #expect(GlyphSpec.Editing.underlineWidth(size: 13) == 13 * 1.2)
        #expect(GlyphSpec.Reading.lineWidth(size: 13) == 13 * 1.2)
        #expect(GlyphSpec.Editing.underlineHeight == 1.5)
        #expect(GlyphSpec.Reading.lineHeight == 1)
    }

    // MARK: Phase -> value

    @Test("The underline is opaque until three quarters in, then fades out linearly")
    func underlineFadeFormula() {
        let opacity = GlyphSpec.Editing.underlineOpacity(written:)
        #expect(opacity(0) == 1)
        #expect(opacity(0.5) == 1)
        #expect(opacity(0.749) == 1)
        #expect(abs(opacity(0.875) - 0.5) < 1e-12)
        #expect(abs(opacity(1)) < 1e-12)
    }

    /// The keyframe replaces the formula, so it has to *be* the formula.
    @Test("The fade keyframe interpolates to the formula it replaced")
    func underlineFadeKeyframe() {
        let fade = GlyphSpec.Editing.underlineFade
        #expect(fade.values == [1, 1, 0])
        #expect(fade.keyTimes == [0, GlyphSpec.Editing.fadeStart, 1])
        #expect(fade.values.count == fade.keyTimes.count)

        for step in 0...20 {
            let written = Double(step) / 20
            let interpolated = Self.interpolate(values: fade.values, keyTimes: fade.keyTimes, at: written)
            #expect(abs(interpolated - GlyphSpec.Editing.underlineOpacity(written: written)) < 1e-9,
                    "fade disagrees with the formula at \(written)")
        }
    }

    @Test("The cursor blink is a hard step, on for the first half of every period")
    func blinkKeyframe() {
        let blink = GlyphSpec.Running.blinkOpacity
        #expect(blink.values == [1, 0])
        // `.discrete` wants one more key time than it has values — the last one closes the
        // final segment. Getting this wrong makes Core Animation drop the animation silently.
        #expect(blink.keyTimes.count == blink.values.count + 1)
        #expect(blink.keyTimes == [0, 0.5, 1])

        let period = GlyphSpec.Running.blink.period
        // The same on/off the timeline read off `GlyphMotion.blink`.
        #expect(GlyphMotion.blink(Self.epoch.addingTimeInterval(0.2), period: period) == (blink.values[0] == 1))
        #expect(GlyphMotion.blink(Self.epoch.addingTimeInterval(0.3), period: period) == (blink.values[1] == 1))
    }

    // MARK: Reduce Motion

    @Test("Reduce Motion loops nothing, and every glyph that has a symbol falls back to it")
    func reducedDrawings() {
        #expect(ActivityGlyph.drawing(for: .editing, reduced: true) == .still(symbol: "pencil.line"))
        #expect(ActivityGlyph.drawing(for: .reading, reduced: true) == .still(symbol: "magnifyingglass"))
        #expect(ActivityGlyph.drawing(for: .running, reduced: true) == .still(symbol: "terminal"))
        #expect(ActivityGlyph.drawing(for: .waiting, reduced: true) == .still(symbol: "hand.raised.fill"))
        #expect(ActivityGlyph.drawing(for: .completed, reduced: true) == .still(symbol: "checkmark"))
        #expect(ActivityGlyph.drawing(for: .failed, reduced: true) == .still(symbol: "xmark"))
        // The dots have no symbol to fall back to, so they draw themselves at rest.
        #expect(ActivityGlyph.drawing(for: .thinking, reduced: true) == .dots(animated: false))
        #expect(ActivityGlyph.drawing(for: .idle, reduced: true) == .nothing)

        for kind in [ActivityKind.editing, .reading, .running, .waiting, .thinking, .completed, .failed, .idle] {
            let drawing = ActivityGlyph.drawing(for: kind, reduced: true)
            if case .looping = drawing { Issue.record("\(kind) still loops under Reduce Motion") }
            #expect(drawing != .dots(animated: true))
        }
    }

    @Test("With motion allowed the four working kinds get their looping glyph and nothing else does")
    func fullMotionDrawings() {
        #expect(ActivityGlyph.drawing(for: .editing, reduced: false) == .looping(.editing))
        #expect(ActivityGlyph.drawing(for: .reading, reduced: false) == .looping(.reading))
        #expect(ActivityGlyph.drawing(for: .running, reduced: false) == .looping(.running))
        #expect(ActivityGlyph.drawing(for: .waiting, reduced: false) == .looping(.waiting))
        #expect(ActivityGlyph.drawing(for: .thinking, reduced: false) == .dots(animated: true))
        #expect(ActivityGlyph.drawing(for: .completed, reduced: false) == .completed)
        #expect(ActivityGlyph.drawing(for: .failed, reduced: false) == .failed)
        #expect(ActivityGlyph.drawing(for: .idle, reduced: false) == .nothing)

        // Every looping kind is reachable, and no two kinds share one.
        let looped = Set(GlyphLayerKind.allCases.map(ActivityGlyph.Drawing.looping))
        let reached = Set(
            [ActivityKind.editing, .reading, .running, .waiting].map {
                ActivityGlyph.drawing(for: $0, reduced: false)
            }
        )
        #expect(reached == looped)
    }

    // MARK: The layer trees

    @Test("Each glyph builds the loops it needs, on its own periods", arguments: [
        (GlyphLayerKind.editing, ["sway", "write", "fade"]),
        (.reading, ["scan"]),
        (.running, ["type", "type", "blink"]),
        (.waiting, ["wave"]),
    ])
    func builtLoops(kind: GlyphLayerKind, keys: [String]) {
        let box = CGSize(width: ActivityGlyph.boxWidth(for: 13), height: ActivityGlyph.boxHeight(for: 13))
        let built = GlyphLayerBuilder.build(kind: kind, size: 13, box: box)
        #expect(built.bindings.map(\.key) == keys)
        #expect(!built.layers.isEmpty)

        for binding in built.bindings {
            // The whole point: handed over once, and never stopping on its own.
            #expect(binding.animation.repeatCount == .infinity)
            #expect(binding.animation.duration > 0)
            // A wave begins half its forward leg in, so it starts at rest and moving rather
            // than pinned at one extreme; a ramp begins where `GlyphMotion.phase` did.
            let expected = binding.animation.autoreverses ? binding.animation.duration / 2 : 0
            #expect(abs(binding.animation.timeOffset - expected) < 1e-12,
                    "\(kind).\(binding.key) starts at the wrong point in its cycle")
        }
    }

    @Test("The pencil sways ±3 pt on its position, on the ease an autoreversing SwiftUI loop uses")
    func editingSwayAnimation() throws {
        let box = Self.box(13)
        let built = GlyphLayerBuilder.build(kind: .editing, size: 13, box: box)
        let sway = try #require(
            built.bindings.first { $0.key == "sway" }?.animation as? CABasicAnimation
        )
        // On `position`, not on the transform, so it composes with the −25° tilt the way
        // SwiftUI's `.offset` after `.rotationEffect` did.
        #expect(sway.keyPath == "position.x")
        let from = try #require(sway.fromValue as? CGFloat)
        let to = try #require(sway.toValue as? CGFloat)
        #expect(abs((from + to) / 2 - box.width / 2) < 1e-9, "the sway is not centred in the box")
        #expect(abs((to - from) / 2 - GlyphSpec.Editing.swayDistance) < 1e-9)

        #expect(sway.autoreverses)
        #expect(sway.duration == GlyphSpec.Editing.sway.duration)
        #expect(Self.isEaseInEaseOut(sway.timingFunction))
    }

    @Test("Every wave eases in and out; every ramp is linear")
    func timingFunctions() {
        for kind in GlyphLayerKind.allCases {
            let built = GlyphLayerBuilder.build(kind: kind, size: 13, box: Self.box(13))
            for binding in built.bindings {
                guard let basic = binding.animation as? CABasicAnimation else { continue }
                if basic.autoreverses {
                    #expect(Self.isEaseInEaseOut(basic.timingFunction),
                            "\(kind).\(binding.key) is not eased")
                } else {
                    #expect(Self.isLinear(basic.timingFunction),
                            "\(kind).\(binding.key) is not linear")
                }
            }
        }
    }

    @Test("The writing underline grows from nothing to the full rule, leftwards-anchored")
    func editingWriteAnimation() throws {
        let built = GlyphLayerBuilder.build(kind: .editing, size: 13, box: Self.box(13))
        let write = try #require(
            built.bindings.first { $0.key == "write" }?.animation as? CABasicAnimation
        )
        #expect(write.fromValue as? CGFloat == 0)
        #expect(write.toValue as? CGFloat == GlyphSpec.Editing.underlineWidth(size: 13))
        #expect(write.duration == GlyphSpec.Editing.write.duration)

        let underline = try #require(
            built.layers.first { $0.backgroundColor == CodePalette.salmonInk.cgColor }
        )
        #expect(underline.anchorPoint == CGPoint(x: 0, y: 0.5))
    }

    @Test("The terminal's cursor rides the same ramp as the line it follows")
    func runningCursorTracksTheLine() {
        let built = GlyphLayerBuilder.build(kind: .running, size: 13, box: Self.box(13))
        let ramps = built.bindings.filter { $0.key == "type" }.compactMap { $0.animation as? CABasicAnimation }
        #expect(ramps.count == 2)
        // Same clock: the cursor was pushed along by the line's width inside an `HStack`, and
        // a frame where the two disagreed would show the cursor inside the line or off it.
        #expect(Set(ramps.map(\.duration)) == [GlyphSpec.Running.type.duration])
        let travelled = ramps.map { ($0.toValue as? CGFloat ?? 0) - ($0.fromValue as? CGFloat ?? 0) }
        #expect(travelled.allSatisfy { abs($0 - GlyphSpec.Running.lineWidth(size: 13)) < 1e-9 })
    }

    @Test("The hand turns about its wrist, not its middle, and both ends of the sweep are converted")
    func waitingAnchor() throws {
        let built = GlyphLayerBuilder.build(kind: .waiting, size: 13, box: Self.box(13))
        // `.bottom` in SwiftUI is `(0.5, 0)` in a y-up layer.
        #expect(built.layers.first?.anchorPoint == CGPoint(x: 0.5, y: 0))

        let wave = try #require(built.bindings.first?.animation as? CABasicAnimation)
        #expect(wave.keyPath == "transform.rotation.z")
        // SwiftUI's +12° is clockwise; a layer's is the other way, so `from` is the *negative*
        // radian for the positive tilt. Both ends go through the same conversion — taking the
        // magnitude of one and negating it would have dropped the flip silently.
        #expect(wave.fromValue as? CGFloat == GlyphLayerBuilder.layerRadians(degrees: GlyphSpec.Waiting.tilt))
        #expect(wave.toValue as? CGFloat == GlyphLayerBuilder.layerRadians(degrees: -GlyphSpec.Waiting.tilt))
        let amplitude = CGFloat(GlyphSpec.Waiting.tilt * .pi / 180)
        #expect(abs((wave.toValue as? CGFloat ?? 0) - amplitude) < 1e-9)
        #expect(abs((wave.fromValue as? CGFloat ?? 0) + amplitude) < 1e-9)
    }

    // MARK: Off screen

    /// The half of the off-screen rule that needs no window: a glyph that has never been in
    /// one has handed nothing to the render server.
    @Test("A glyph outside a window runs nothing, however keen it is")
    func noWindowNoLoops() {
        let view = GlyphLayerView(kind: .editing, size: 13, animates: true)
        #expect(view.attachedLoopCount == 0)
        view.animates = false
        #expect(view.attachedLoopCount == 0)
    }

    @Test("Loops start when the glyph joins a window and stop the moment it leaves one")
    func loopsFollowTheWindow() {
        let window = Self.window()
        defer { window.close() }
        let view = GlyphLayerView(kind: .running, size: 13, animates: true)
        window.contentView?.addSubview(view)
        #expect(view.attachedLoopCount == 3)

        // Reduce Motion turned on while the glyph is on screen stops it where it stands.
        view.animates = false
        #expect(view.attachedLoopCount == 0)
        view.animates = true
        #expect(view.attachedLoopCount == 3)

        // A layer in a window-less view still burns CPU with an animation attached.
        view.removeFromSuperview()
        #expect(view.attachedLoopCount == 0)
    }

    // MARK: Updating in place

    /// SwiftUI hands the same view back for a different kind or a different type size, and
    /// `.id(layerKind)` — which lives in another file and says nothing about `size` — is not
    /// enough on its own. A glyph that ignored this would draw the compact slot's 13 pt
    /// artwork inside the header's 12 pt box.
    @Test("A different type size rebuilds the layer tree")
    func updateRebuildsOnSize() throws {
        let view = GlyphLayerView(kind: .editing, size: 13, animates: true)
        #expect(view.intrinsicContentSize == GlyphLayerView.box(for: 13))
        let before = try #require(view.layer?.sublayers?.last)
        #expect(before.bounds.width == GlyphSpec.Editing.underlineWidth(size: 13))

        view.update(kind: .editing, size: 12, animates: true)
        #expect(view.size == 12)
        #expect(view.intrinsicContentSize == GlyphLayerView.box(for: 12))
        #expect(view.frame.size == GlyphLayerView.box(for: 12))
        let after = try #require(view.layer?.sublayers?.last)
        #expect(after.bounds.width == GlyphSpec.Editing.underlineWidth(size: 12))
        #expect(after.bounds.width != before.bounds.width)
    }

    @Test("A different kind rebuilds the layer tree, and the old loops go with it")
    func updateRebuildsOnKind() throws {
        let window = Self.window()
        defer { window.close() }
        let view = GlyphLayerView(kind: .editing, size: 13, animates: true)
        window.contentView?.addSubview(view)
        #expect(view.attachedLoopCount == 3)
        let stale = try #require(view.layer?.sublayers?.last)

        view.update(kind: .waiting, size: 13, animates: true)
        #expect(view.kind == .waiting)
        // The hand is one layer, and the pencil's three loops are not still attached to
        // layers nobody can see.
        #expect(view.layer?.sublayers?.count == 1)
        #expect(view.attachedLoopCount == 1)
        #expect(stale.superlayer == nil)
        #expect(stale.animationKeys()?.isEmpty ?? true)
    }

    @Test("An update that changes nothing but Reduce Motion keeps the artwork it has")
    func updateKeepsTheTreeWhenOnlyMotionChanges() throws {
        let view = GlyphLayerView(kind: .reading, size: 13, animates: true)
        let before = try #require(view.layer?.sublayers?.first)
        view.update(kind: .reading, size: 13, animates: false)
        #expect(view.layer?.sublayers?.first === before)
    }

    // MARK: Helpers

    static func box(_ size: CGFloat) -> CGSize { GlyphLayerView.box(for: size) }

    static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        // A window made in code is released when it is closed, which ARC then releases
        // again: `close()` in a `defer` crashes the whole test process without this.
        window.isReleasedWhenClosed = false
        return window
    }

    /// `CAMediaTimingFunction` has no equality, so its control points stand in for it.
    static func matches(_ function: CAMediaTimingFunction?, _ name: CAMediaTimingFunctionName) -> Bool {
        guard let function else { return false }
        let expected = CAMediaTimingFunction(name: name)
        for index in 0...3 {
            var lhs = [Float](repeating: 0, count: 2)
            var rhs = [Float](repeating: 0, count: 2)
            function.getControlPoint(at: index, values: &lhs)
            expected.getControlPoint(at: index, values: &rhs)
            guard lhs == rhs else { return false }
        }
        return true
    }

    static func isEaseInEaseOut(_ function: CAMediaTimingFunction?) -> Bool {
        matches(function, .easeInEaseOut)
    }

    static func isLinear(_ function: CAMediaTimingFunction?) -> Bool {
        matches(function, .linear)
    }

    /// Linear interpolation across a keyframe's stops — what Core Animation does with
    /// `calculationMode = .linear`.
    private static func interpolate(values: [Double], keyTimes: [Double], at time: Double) -> Double {
        guard let last = values.indices.last else { return 0 }
        if time <= keyTimes[0] { return values[0] }
        for index in 0..<last where time <= keyTimes[index + 1] {
            let span = keyTimes[index + 1] - keyTimes[index]
            guard span > 0 else { return values[index + 1] }
            let fraction = (time - keyTimes[index]) / span
            return values[index] + (values[index + 1] - values[index]) * fraction
        }
        return values[last]
    }
}
