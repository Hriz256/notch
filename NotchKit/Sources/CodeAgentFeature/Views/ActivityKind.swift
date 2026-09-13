import AppKit
import CodeAgentShared
import IslandCore
import SwiftUI

/// What the agent is *doing*, as one word — the thing the compact island's 56 pt
/// trailing slot has room to say.
///
/// ``Stage`` alone cannot answer it: the hook mappers fold both "editing a file" and
/// "running a command" into ``Stage/creating``, and a command is the one kind a user
/// wants to recognize from the corner of the eye. So the kind is derived from the stage
/// *and* the tool name, with the tool winning whenever it is one Notch knows.
///
/// Pure and total by design: no I/O, no view state, one value per `(stage, tool)` pair.
enum ActivityKind: Equatable, Sendable {
    /// Looking at the project: reads, greps, searches, fetches.
    case reading
    /// Writing to the project: edits, new files, patches.
    case editing
    /// A shell command.
    case running
    /// Between tools. Drawn as the typing dots, so the slot is never empty mid-session.
    case thinking
    /// The agent needs the user.
    case waiting
    case completed
    case failed
    /// No session: the slot belongs to ``SessionRing``.
    case idle

    /// Tool names that mean "a shell command is running". They come out of
    /// ``StageMapper`` as `.creating`, so the classification has to happen here.
    private static let commandTools: Set<String> = [
        "Bash", "shell", "exec_command", "Shell",
    ]
    /// Tool names that write to the project (`afterFileEdit` is Cursor's edit *event*,
    /// which reaches the session as a stage without a tool — listed for completeness).
    private static let editingTools: Set<String> = [
        "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "afterFileEdit",
    ]
    /// Tool names that only look at things.
    private static let readingTools: Set<String> = [
        "Read", "Grep", "Glob", "Agent", "Explore", "WebFetch", "WebSearch", "LSP",
        "read_file", "view_image", "list_dir", "Search", "List", "Codebase",
    ]

    /// The stage says which family the work is in; a known tool name refines it.
    ///
    /// A `nil` stage is the idle island. An unknown tool (an MCP tool, say) falls back to
    /// the stage, so a new tool name degrades to "reading" or "editing" rather than to
    /// nothing at all.
    static func from(stage: Stage?, tool: String?) -> ActivityKind {
        guard let stage else { return .idle }
        switch stage {
        case .waiting: return .waiting
        case .completed: return .completed
        case .failed: return .failed
        case .analyzing, .creating, .thinking: break
        }

        let name = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            if commandTools.contains(name) { return .running }
            if editingTools.contains(name) { return .editing }
            if readingTools.contains(name) { return .reading }
        }

        switch stage {
        case .analyzing: return .reading
        case .creating: return .editing
        // Thinking without a tool of its own is the one kind that shows nothing.
        default: return .thinking
        }
    }

    /// `nil` for the two kinds that have no SF symbol: ``idle`` draws nothing at all, and
    /// ``thinking`` is drawn by hand as ``ThinkingDots``.
    var symbol: String? {
        switch self {
        case .reading: "magnifyingglass"
        case .editing: "pencil.line"
        case .running: "terminal"
        case .waiting: "hand.raised.fill"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .thinking, .idle: nil
        }
    }

    /// Whether this kind puts something in the slot. Only ``idle`` — which means "no
    /// session", and hands the slot to ``SessionRing`` — draws nothing.
    var drawsGlyph: Bool { self != .idle }

    /// The three kinds a tool call produces. They are the ones ``ActivityDwell`` holds on
    /// screen: a `PostToolUse` that lands milliseconds after its `PreToolUse` would
    /// otherwise flash the glyph and take it away again.
    var isTool: Bool {
        switch self {
        case .reading, .editing, .running: true
        case .thinking, .waiting, .completed, .failed, .idle: false
        }
    }

    /// Only the three kinds that need the user are colored, so a colored glyph in the
    /// corner of the eye always means "something changed".
    var color: Color {
        switch self {
        case .waiting: CodePalette.amber
        case .completed: CodePalette.green
        case .failed: CodePalette.red
        case .reading, .editing, .running, .thinking, .idle: .white
        }
    }

    /// The one word for this kind — the activity panel's header, and the glyph's
    /// accessibility label.
    ///
    /// Deliberately the same wording ``StageLabel`` uses for the stage each kind comes
    /// from (`.editing` is a `.creating` stage, so it reads "Creating"): the header word is
    /// derived from the *smoothed* kind, and a session whose glyph and word disagreed —
    /// the pencil beside "Thinking" — was the bug this property exists to prevent.
    var label: String {
        switch self {
        case .reading: "Reading"
        case .editing: "Creating"
        case .running: "Running"
        case .thinking: "Thinking"
        case .waiting: "Waiting for you"
        case .completed: "Done"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }
}

// MARK: - Dwell

/// Slows the glyph down to human speed.
///
/// Hooks fire far faster than an eye can follow: a `Read` of a small file is a
/// `PreToolUse`/`PostToolUse` pair milliseconds apart, so the honest glyph appears and
/// vanishes inside one frame, and a burst of tools reads as a flicker rather than as work.
/// This value type folds the *wanted* kind into the *shown* one under two rules:
///
/// - a tool glyph that has just appeared keeps the slot for ``minimumDwell`` before another
///   tool glyph may take it;
/// - when the tool ends (`PostToolUse` clears the tool and the stage falls back to
///   thinking) the last tool glyph lingers for ``toolLinger``, so a gap between two tools
///   does not blink the dots on and off in between.
///
/// The kinds that need the user — ``ActivityKind/waiting``, ``ActivityKind/completed``,
/// ``ActivityKind/failed`` — and ``ActivityKind/idle`` are never held back: they are the
/// ones worth interrupting for.
///
/// Pure: every decision is a function of the target and the two timestamps, so the whole
/// timeline is testable without a view or a run loop. ``update(target:now:)`` hands back the
/// date at which it wants to be called again (`nil` when it is already settled).
struct ActivityDwell: Equatable, Sendable {
    /// How long a tool glyph owns the slot once it appears.
    static let minimumDwell: TimeInterval = 1.5
    /// How long the last tool glyph stays after the tool ends, waiting for the next one.
    static let toolLinger: TimeInterval = 2

    /// What the island is drawing right now.
    private(set) var visible: ActivityKind = .idle
    /// When ``visible`` appeared. `nil` before the first update.
    private(set) var shownAt: Date?
    /// When the target stopped being a tool — the start of the ``toolLinger`` window.
    private(set) var toolEndedAt: Date?

    /// Folds the kind the session *is* into the kind the island *shows*.
    /// - Returns: when to call this again with the same target, or `nil` if nothing is pending.
    mutating func update(target: ActivityKind, now: Date) -> Date? {
        if target.isTool {
            toolEndedAt = nil
        } else if target == .thinking {
            // Only the first thinking target after a tool opens the linger window; the
            // refreshes that follow must not push it further out.
            if toolEndedAt == nil { toolEndedAt = now }
        } else {
            toolEndedAt = nil
        }

        // Nothing to protect: no tool glyph on screen, the same glyph again, or news the
        // user is owed now — a prompt, a finish, or the end of the session.
        guard visible.isTool, target != visible, target.isTool || target == .thinking else {
            show(target, at: now)
            return nil
        }

        let dwellUntil = (shownAt ?? now).addingTimeInterval(Self.minimumDwell)
        let due = target.isTool
            ? dwellUntil
            : max(dwellUntil, (toolEndedAt ?? now).addingTimeInterval(Self.toolLinger))

        guard now >= due else { return due }
        show(target, at: now)
        return nil
    }

    private mutating func show(_ kind: ActivityKind, at now: Date) {
        guard kind != visible else { return }
        visible = kind
        shownAt = now
    }
}

/// The single animated glyph that says what the agent is doing, in the compact island's
/// trailing slot and in the activity panel's header.
///
/// Each kind gets a hand-made animation rather than an SF symbol effect: the effects are
/// generic ("this symbol is busy") where the island wants to say *what* the agent is busy
/// with, and none of them reads at 13 pt. Every animation is bound to a working kind and
/// lives inside this view, so an idle island — which draws ``SessionRing`` instead —
/// animates nothing at all.
///
/// Reduce Motion collapses all of them to a still mark.
struct ActivityGlyph: View {
    let kind: ActivityKind
    var size: CGFloat = 13

    /// Every glyph draws inside the same box, so swapping kinds never shifts the text
    /// next to it. Three points taller than the type size for the underline the editing
    /// and reading glyphs draw beneath their symbol.
    static func boxHeight(for size: CGFloat) -> CGFloat { size + 3 }
    static func boxWidth(for size: CGFloat) -> CGFloat { size * 1.6 }

    var body: some View {
        // Only the idle island draws nothing *and* takes no room; every stage of a live
        // session has a mark of its own, thinking included.
        if kind.drawsGlyph {
            content
                .frame(width: Self.boxWidth(for: size), height: Self.boxHeight(for: size))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(kind.label)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch Self.drawing(for: kind, reduced: GlyphMotion.isReduced) {
        case .looping(let layerKind):
            // All four looping kinds share this branch, so they would otherwise share one
            // view identity — and one `GlyphLayerView`, whose layer tree is built once. The
            // id both separates them and, within a kind, holds the loop steady through the
            // island's re-renders, which is what the timelines used to buy for free.
            LoopingGlyph(kind: layerKind, size: size)
                .id(layerKind)
        case .dots(let animated):
            ThinkingDots(isAnimating: animated)
        case .still(let symbol):
            Image(systemName: symbol)
                .font(.system(size: size * GlyphSpec.symbolScale, weight: .semibold))
                .foregroundStyle(kind.color)
        case .completed:
            CompletedGlyph(size: size)
        case .failed:
            FailedGlyph(size: size)
        case .nothing:
            EmptyView()
        }
    }

    /// What ``content`` draws, as a value.
    ///
    /// Split out so the one decision Reduce Motion makes here is testable without a renderer:
    /// under the setting nothing loops, every glyph that has an SF symbol falls back to it
    /// still, and the dots — which have no symbol — draw themselves at rest.
    enum Drawing: Hashable, Sendable {
        /// One of the four working marks, looping on Core Animation.
        case looping(GlyphLayerKind)
        /// The thinking dots, moving or at rest.
        case dots(animated: Bool)
        /// A still SF symbol: what every looping glyph degrades to under Reduce Motion.
        case still(symbol: String)
        /// The two that play once and stop. Reduce Motion replaces them with their symbols.
        case completed
        case failed
        case nothing
    }

    static func drawing(for kind: ActivityKind, reduced: Bool) -> Drawing {
        if reduced {
            // The dots have no SF symbol to fall back to, so they draw themselves still.
            if kind == .thinking { return .dots(animated: false) }
            guard let symbol = kind.symbol else { return .nothing }
            return .still(symbol: symbol)
        }
        switch kind {
        case .editing: return .looping(.editing)
        case .reading: return .looping(.reading)
        case .running: return .looping(.running)
        case .waiting: return .looping(.waiting)
        case .completed: return .completed
        case .failed: return .failed
        case .thinking: return .dots(animated: true)
        case .idle: return .nothing
        }
    }
}

// MARK: - Motion helpers

/// The one place this feature consults Reduce Motion, and the definitions the glyph loops are
/// shaped from.
///
/// The four working glyphs no longer *call* the three functions below — they are
/// ``GlyphLoop``s handed to Core Animation once, in `GlyphLayers.swift`, rather than bodies
/// re-run at display rate. The functions stay because they are the statement of what each loop
/// is: a ramp, a wave, a blink, on a named period. The tests hold the Core Animation
/// parameters against them, which is the only way the two halves can be kept honest.
@MainActor
enum GlyphMotion {
    /// Live, not sampled: ``MotionSettings`` is `@Observable` and refreshes from one workspace
    /// notification, so a view that reads this while building its body is re-drawn the moment
    /// the user turns Reduce Motion on — which the old direct `NSWorkspace` read only managed
    /// because every glyph happened to be re-drawing every frame anyway.
    static var isReduced: Bool { MotionSettings.shared.isReduced }

    /// `0 → 1`, restarting every `period` seconds. The "grows then resets" ramp.
    static func phase(_ date: Date, period: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return t / period
    }

    /// `0 → 1 → -1 → 0` once per `period`. A sine, so it eases in and out at both ends
    /// exactly the way an autoreversing `.easeInOut` does.
    static func wave(_ date: Date, period: Double) -> Double {
        sin(phase(date, period: period) * 2 * .pi)
    }

    /// On for the first half of every `period`, off for the second — a cursor blink.
    static func blink(_ date: Date, period: Double) -> Bool {
        phase(date, period: period) < 0.5
    }
}

// MARK: - The glyphs

/// Three dots that rise in turn — the "still with you" indicator every chat app uses, at
/// the one size a notch has room for.
///
/// Deliberately the quietest glyph in the set: thinking is the state the island spends most
/// of a session in, and anything livelier than a slow wave would be a distraction for
/// minutes at a time. Fixed points rather than multiples of `size`: at 3 pt a dot is already
/// at the floor of what renders as a circle, so the header and the compact slot draw the
/// same one.
/// These dots are driven by Core Animation — one `repeatForever` offset per dot, started once
/// on appear. Thinking is the state a session spends most of its life in, and a
/// `TimelineView(.animation)` redraws the whole island's SwiftUI body every frame for as long
/// as it is on screen: minutes of display-rate re-renders for three 3 pt circles. A repeating
/// animation is handed to the render server once and costs nothing per frame. The dots were
/// the first glyph to work this way and are the model the other four now follow (see
/// `GlyphLayers.swift`), which is the same argument applied to the rest of a session.
struct ThinkingDots: View {
    var isAnimating: Bool = true

    static let count = 3
    static let diameter: CGFloat = 3
    static let spacing: CGFloat = 3
    /// One rise (or one fall): the animation autoreverses, so a full bob is twice this.
    static let duration: Double = 0.45
    /// How far behind its neighbour each dot runs.
    static let stagger: Double = 0.15
    static let rise: CGFloat = 2

    /// Whether the dots actually move: Reduce Motion is answered here as well as in
    /// ``ActivityGlyph`` so no caller can start the loop behind the setting's back.
    private var animates: Bool { isAnimating && !GlyphMotion.isReduced }

    /// The loop for dot `index`: the same easing every chat app's typing indicator uses,
    /// each dot one ``stagger`` behind the one before it, so the row reads as a wave
    /// rather than as three dots blinking together.
    static func animation(index: Int) -> Animation {
        .easeInOut(duration: duration)
        .repeatForever(autoreverses: true)
        .delay(Double(index) * stagger)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<Self.count, id: \.self) { index in
                Dot(index: index, animates: animates)
            }
        }
        // The tallest the row ever gets, claimed always, so the dots do not shove the
        // baseline around as they rise.
        .frame(height: Self.diameter + Self.rise)
        // Reduce Motion (and the still row generally) is dimmer, so a row that does not
        // move still reads as "waiting" rather than as a finished state.
        .foregroundStyle(.white.opacity(animates ? 0.7 : 0.5))
    }

    /// One dot, owning its own lifted state so each can carry its own delay.
    private struct Dot: View {
        let index: Int
        let animates: Bool

        @State private var lifted = false

        var body: some View {
            Circle()
                .frame(width: ThinkingDots.diameter, height: ThinkingDots.diameter)
                .offset(y: lifted ? -ThinkingDots.rise : 0)
                .onAppear {
                    guard animates else { return }
                    withAnimation(ThinkingDots.animation(index: index)) { lifted = true }
                }
        }
    }
}

// The four working glyphs — the pencil, the magnifier, the terminal and the raised hand —
// live in `GlyphLayers.swift`. They used to be four `TimelineView(.animation)` bodies here,
// which is to say four SwiftUI graphs re-evaluated at display rate for as long as an agent
// worked; they are now `CALayer`s with repeating animations, reached through ``LoopingGlyph``.
// Their shapes, sizes, colours, periods and easing are unchanged and now pinned by tests.

/// A checkmark that draws itself once, when the session finishes.
private struct CompletedGlyph: View {
    let size: CGFloat

    @State private var drawn: CGFloat = 0

    var body: some View {
        CheckShape()
            .trim(from: 0, to: drawn)
            .stroke(CodePalette.green,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: size * 0.9, height: size * 0.66)
            .onAppear {
                // No repeat: "done" happens once, and a looping tick would keep asking
                // for attention the session no longer needs.
                withAnimation(.easeOut(duration: 0.35)) { drawn = 1 }
            }
    }
}

/// The tick, as a two-segment path so `.trim` draws it in the order a hand would.
private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A cross that shakes its head once.
private struct FailedGlyph: View {
    let size: CGFloat

    @State private var shake: CGFloat = 0

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: size * 0.85, weight: .semibold))
            .foregroundStyle(CodePalette.red)
            .modifier(ShakeEffect(progress: shake))
            .onAppear {
                withAnimation(.linear(duration: 0.35)) { shake = 1 }
            }
    }
}

/// Three horizontal cycles of ±2 pt over the life of `progress` (0 → 1).
private struct ShakeEffect: GeometryEffect {
    var progress: CGFloat

    private static let amplitude: CGFloat = 2
    private static let cycles: CGFloat = 3

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(progress * .pi * 2 * Self.cycles) * Self.amplitude
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
