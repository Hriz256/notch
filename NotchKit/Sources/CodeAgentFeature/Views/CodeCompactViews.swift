import CodeAgentShared
import IslandCore
import SwiftUI

/// The island's leading peek slot: which agent this card is about.
///
/// The icon is the one constant of the Code island — it is on screen in every state,
/// idle or working — so the stage is expressed by animating *it* (the thinking pulse)
/// rather than by swapping it out.
struct CodeCompactLeading: View {
    let model: CodeAgentViewModel

    var body: some View {
        AgentIcon(
            agent: model.displayedAgent,
            size: 18,
            isPulsing: model.visibleStage == .thinking
        )
        // The slot is exactly ``IslandLayout/peekSlotWidth`` wide and the icon must sit in
        // the middle of it. Stating the width here rather than inheriting the proposal
        // keeps the icon off the notch's edge whatever the surface proposes — without it a
        // glyph that measures wider than it draws drifts toward the notch and clips.
        .codeSlot()
        .codeContextMenu(model)
    }
}

/// The island's trailing peek slot: the session ring while idle, one animated glyph while
/// working.
///
/// The two are mutually exclusive by design — usage is the answer to "how much is left",
/// which nobody asks while they are watching the agent type. No words either: 56 pt next
/// to the notch is room for a symbol, and a six-character tool stump was never legible
/// enough to earn the space. The full tool name is still in the expanded header.
struct CodeCompactTrailing: View {
    let model: CodeAgentViewModel

    /// Big enough to read at arm's length, small enough to sit inside the notch's height.
    static let glyphSize: CGFloat = 13

    var body: some View {
        content
            .codeSlot()
            .codeContextMenu(model)
    }

    @ViewBuilder
    private var content: some View {
        switch Self.slot(for: model) {
        case .ring(let percent):
            SessionRing(percent: percent)
        case .unavailable:
            // A ring drawn at 0 % would read as "plenty left"; the dim mark says instead
            // that there is nothing to report, and the expanded panel says why.
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: Self.glyphSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityLabel("Usage unavailable")
        case .activity(let kind):
            // `.thinking` draws nothing: the pulsing agent icon on the other side of the
            // notch already says the agent is between tools.
            ActivityGlyph(kind: kind, size: Self.glyphSize)
        }
    }

    /// What the slot draws. Split out of `body` so the choice is testable without rendering.
    enum Slot: Equatable {
        case ring(Double)
        case unavailable
        case activity(ActivityKind)
    }

    static func slot(for model: CodeAgentViewModel) -> Slot {
        let kind = ActivityKind.from(stage: model.visibleStage, tool: model.displayedSession?.tool)
        guard kind == .idle else { return .activity(kind) }
        guard model.usageError == nil else { return .unavailable }
        return .ring(model.displayedUsage?.session?.percent ?? 0)
    }
}

extension View {
    /// Centres a peek-slot glyph in the 56 pt the surface gives it, vertically as well as
    /// horizontally. Both Code slots use it, so neither can drift under the notch.
    func codeSlot() -> some View {
        frame(width: IslandLayout.peekSlotWidth, alignment: .center)
            .frame(maxHeight: .infinity, alignment: .center)
    }
}
