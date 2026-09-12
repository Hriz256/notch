import AppKit
import CodeAgentShared
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

    var label: String {
        switch self {
        case .reading: "Reading"
        case .editing: "Editing"
        case .running: "Running a command"
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
        if GlyphMotion.isReduced {
            // The dots have no SF symbol to fall back to, so they draw themselves still.
            if kind == .thinking {
                ThinkingDots(isAnimating: false)
            } else if let symbol = kind.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundStyle(kind.color)
            }
        } else {
            switch kind {
            case .editing: EditingGlyph(size: size)
            case .reading: ReadingGlyph(size: size)
            case .running: RunningGlyph(size: size)
            case .waiting: WaitingGlyph(size: size)
            case .completed: CompletedGlyph(size: size)
            case .failed: FailedGlyph(size: size)
            case .thinking: ThinkingDots()
            case .idle: EmptyView()
            }
        }
    }
}

// MARK: - Motion helpers

/// The shared clock math behind the looping glyphs, and the one place Reduce Motion is
/// consulted.
///
/// The loops are driven by the date `TimelineView(.animation)` hands out rather than by
/// `repeatForever` animations: a repeating animation attached to a view that SwiftUI
/// re-creates on every model change restarts mid-cycle, whereas a function of wall-clock
/// time is continuous no matter how often the island re-renders.
@MainActor
enum GlyphMotion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
struct ThinkingDots: View {
    var isAnimating: Bool = true

    static let count = 3
    static let diameter: CGFloat = 3
    static let spacing: CGFloat = 3
    /// One full pass of the wave.
    static let period: Double = 0.9
    /// How far behind its neighbour each dot runs.
    static let stagger: Double = 0.15
    static let rise: CGFloat = 2
    /// The share of the loop one dot spends off the ground.
    private static let bump: Double = 1.0 / 3

    /// How far dot `index` is lifted at `date`, in points. A half sine over the first third
    /// of its loop and flat for the rest, so the dot eases up, eases down and then rests.
    static func lift(_ date: Date, index: Int) -> CGFloat {
        let shifted = date.addingTimeInterval(-Double(index) * stagger)
        let phase = GlyphMotion.phase(shifted, period: period)
        guard phase < bump else { return 0 }
        return CGFloat(sin(phase / bump * .pi)) * rise
    }

    var body: some View {
        if isAnimating {
            TimelineView(.animation) { context in
                row(at: context.date)
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else {
            // Reduce Motion: the same three dots, dimmer so a still row still reads as
            // "waiting" rather than as a finished state.
            row(at: nil)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// `nil` is the still row — the dots on the ground.
    private func row(at date: Date?) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<Self.count, id: \.self) { index in
                Circle()
                    .frame(width: Self.diameter, height: Self.diameter)
                    .offset(y: -(date.map { Self.lift($0, index: index) } ?? 0))
            }
        }
        // The tallest the row ever gets, claimed always, so the dots do not shove the
        // baseline around as they rise.
        .frame(height: Self.diameter + Self.rise)
    }
}

/// A tilted pencil sliding back and forth over a salmon underline that writes itself.
private struct EditingGlyph: View {
    let size: CGFloat

    private static let swayPeriod: Double = 0.9
    private static let sway: CGFloat = 3
    private static let writePeriod: Double = 1.4
    /// The last quarter of the write loop is the fade, so the line never snaps away.
    private static let fadeStart: Double = 0.75

    var body: some View {
        TimelineView(.animation) { context in
            let written = GlyphMotion.phase(context.date, period: Self.writePeriod)
            VStack(spacing: 1.5) {
                Image(systemName: "pencil")
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-25))
                    .offset(x: GlyphMotion.wave(context.date, period: Self.swayPeriod) * Self.sway)
                    .frame(height: size)
                underline(written: written)
            }
        }
    }

    private func underline(written: Double) -> some View {
        let full = size * 1.2
        let opacity = written < Self.fadeStart
            ? 1
            : 1 - (written - Self.fadeStart) / (1 - Self.fadeStart)
        return HStack(spacing: 0) {
            Capsule()
                .fill(CodePalette.salmon)
                .frame(width: full * written, height: 1.5)
                .opacity(opacity)
            Spacer(minLength: 0)
        }
        .frame(width: full)
    }
}

/// A magnifier scanning left and right along a faint line.
private struct ReadingGlyph: View {
    let size: CGFloat

    private static let period: Double = 1.2
    private static let travel: CGFloat = 4

    var body: some View {
        TimelineView(.animation) { context in
            VStack(spacing: 1.5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: GlyphMotion.wave(context.date, period: Self.period) * Self.travel)
                    .frame(height: size)
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: size * 1.2, height: 1)
            }
        }
    }
}

/// A terminal window typing a line, with a blinking cursor after it.
private struct RunningGlyph: View {
    let size: CGFloat

    private static let typePeriod: Double = 1.2
    private static let blinkPeriod: Double = 0.5

    /// The 14 × 10 frame of the spec, expressed against the type size so the glyph still
    /// fits when the header renders it a point smaller than the compact slot does.
    private var frameWidth: CGFloat { size * 1.08 }
    private var frameHeight: CGFloat { size * 0.77 }
    private var cursorHeight: CGFloat { frameHeight * 0.6 }

    var body: some View {
        TimelineView(.animation) { context in
            let typed = GlyphMotion.phase(context.date, period: Self.typePeriod)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(.white, lineWidth: 1)
                .frame(width: frameWidth, height: frameHeight)
                .overlay(alignment: .leading) {
                    HStack(spacing: 1) {
                        Text(">")
                            .font(.system(size: frameHeight * 0.62, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Capsule()
                            .fill(.white)
                            // Sized so prompt, line and cursor still clear the right-hand
                            // stroke when the line is fully typed.
                            .frame(width: (frameWidth * 0.3) * typed, height: 1)
                        Rectangle()
                            .fill(.white)
                            .frame(width: 1, height: cursorHeight)
                            .opacity(GlyphMotion.blink(context.date, period: Self.blinkPeriod) ? 1 : 0)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 1.5)
                    .frame(width: frameWidth, height: frameHeight)
                }
        }
    }
}

/// A raised hand waving from the wrist.
private struct WaitingGlyph: View {
    let size: CGFloat

    private static let period: Double = 0.8
    private static let tilt: Double = 12

    var body: some View {
        TimelineView(.animation) { context in
            Image(systemName: "hand.raised.fill")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(CodePalette.amber)
                // From the wrist, not the middle of the palm: rotating around the centre
                // reads as a spin rather than a wave.
                .rotationEffect(.degrees(GlyphMotion.wave(context.date, period: Self.period) * Self.tilt),
                                anchor: .bottom)
        }
    }
}

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
