import CodeAgentShared
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
            .codeContextMenu(model)
    }

    @ViewBuilder
    private var content: some View {
        let kind = ActivityKind.from(stage: model.visibleStage, tool: model.displayedSession?.tool)
        if kind == .idle {
            SessionRing(percent: model.displayedUsage?.session?.percent ?? 0)
        } else {
            // `.thinking` draws nothing: the pulsing agent icon on the other side of the
            // notch already says the agent is between tools.
            ActivityGlyph(kind: kind, size: Self.glyphSize)
        }
    }
}
