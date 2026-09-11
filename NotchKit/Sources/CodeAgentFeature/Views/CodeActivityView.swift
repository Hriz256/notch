import CodeAgentShared
import NowPlayingShared
import SwiftUI

/// The expanded panel while a session is running, waiting or has just finished.
///
/// Same 380 × 170 card as ``CodeExpandedView`` and the same usage bars at the bottom, so
/// the panel does not re-lay-out when a session starts: only the top half changes, from
/// the sparkline to the stage.
///
/// Height budget (138 pt usable under the notch):
/// `2 (top) + 18 (header) + 8 + 28 (detail, 2 lines) + 8 + 24 + 8 + 24 + 5 (bottom) = 125`,
/// with the slack taken by a spacer so the bars stay pinned to the bottom edge.
struct CodeActivityView: View {
    let model: CodeAgentViewModel

    private var stage: Stage { model.visibleStage ?? .thinking }
    private var session: SessionTracker.Session? { model.displayedSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            detail
            Spacer(minLength: 0)
            CodeUsageBars(model: model, compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.startTicking() }
        .onDisappear { model.stopTicking() }
        .codeContextMenu(model)
    }

    private var header: some View {
        HStack(spacing: 6) {
            AgentIcon(agent: model.displayedAgent, size: 18, isPulsing: stage == .thinking)
            StageGlyph(stage: stage, size: 12)
            Text(StageGlyph.title(stage))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if let tool = session?.tool, !tool.isEmpty {
                Text(tool)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 6)
            Text(elapsedText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .frame(height: 18)
    }

    /// `1:07` — plus `×3` when more than one agent session is running, which is the only
    /// hint the island gives that the elapsed clock belongs to just one of them.
    private var elapsedText: String {
        let elapsed = TimeFormatting.mmss(model.elapsed)
        guard model.activeCount > 1 else { return elapsed }
        return "\(elapsed) ×\(model.activeCount)"
    }

    @ViewBuilder
    private var detail: some View {
        if let text = session?.detail, !text.isEmpty {
            Text(text)
                .font(.system(size: 11))
                // Amber is the island's "this needs you" colour; everywhere else the
                // detail is just context and stays quiet.
                .foregroundStyle(stage == .waiting ? CodePalette.amber : .white.opacity(0.7))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
