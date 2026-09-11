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

/// The island's trailing peek slot: the session ring while idle, the stage while working.
///
/// The two are mutually exclusive by design — usage is the answer to "how much is left",
/// which nobody asks while they are watching the agent type.
struct CodeCompactTrailing: View {
    let model: CodeAgentViewModel

    /// Long tool names are cut rather than ellipsized: at 10 pt in the notch's corner the
    /// "…" would cost a whole readable character.
    static let toolLimit = 6

    var body: some View {
        content
            .codeContextMenu(model)
    }

    @ViewBuilder
    private var content: some View {
        if let stage = model.visibleStage {
            HStack(spacing: 4) {
                StageGlyph(stage: stage, size: 12)
                if let tool = Self.abbreviated(model.displayedSession?.tool) {
                    Text(tool)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        } else {
            SessionRing(percent: model.displayedUsage?.session?.percent ?? 0)
        }
    }

    static func abbreviated(_ tool: String?) -> String? {
        guard let tool else { return nil }
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(toolLimit))
    }
}
