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
    /// Between tools. Deliberately silent in the compact slot — the agent icon pulses instead.
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

    /// `nil` for the two kinds that draw nothing in the slot.
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

/// The single animated glyph that says what the agent is doing, in the compact island's
/// trailing slot and in the activity panel's header.
///
/// Every repeating symbol effect lives here and nowhere else, and each one is bound to a
/// working kind: an idle island draws ``SessionRing`` instead of this view, and the two
/// silent kinds (`thinking`, `idle`) render nothing at all, so nothing animates when
/// there is nothing to watch.
struct ActivityGlyph: View {
    let kind: ActivityKind
    var size: CGFloat = 13

    /// Bumped whenever a one-shot kind arrives; `.symbolEffect(.bounce, value:)` watches it.
    @State private var arrivals = 0

    var body: some View {
        if let symbol = kind.symbol {
            glyph(symbol)
        }
    }

    @ViewBuilder
    private func glyph(_ symbol: String) -> some View {
        let base = Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(kind.color)
            .accessibilityLabel(kind.label)

        switch kind {
        case .reading, .waiting:
            base.symbolEffect(.pulse, isActive: true)
        case .editing:
            // Slowed down: a full-speed repeating bounce reads as frantic at 13 pt.
            base.symbolEffect(.bounce, options: .repeating.speed(0.6))
        case .running:
            // `.variableColor` would be inert here — `terminal` has no variable-colour
            // layers — so the "still going" signal is a slow breathe instead.
            base.symbolEffect(.breathe, options: .repeating.speed(0.8))
        case .completed, .failed:
            base
                .symbolEffect(.bounce, value: arrivals)
                .onAppear { arrivals += 1 }
                .onChange(of: kind) { _, _ in arrivals += 1 }
        case .thinking, .idle:
            base
        }
    }
}
