import CodeAgentShared
import NowPlayingShared
import SwiftUI

/// The expanded panel while a session is running, waiting or has just finished.
///
/// Same 380 pt-wide card as ``CodeExpandedView`` and the same usage bars, but the card
/// shrinks to what there is to show: ``CodeAgentViewModel/expandedSize`` is 132 pt tall
/// without a detail line and 160 pt with one. Nothing here reserves space — an empty
/// detail renders nothing rather than an empty band, and there is no spacer pushing the
/// bars to a bottom edge that is no longer there.
///
/// Height budget (132 pt card, 32 pt of it under the notch):
/// `2 (top) + 18 (header) + 10 + 24 (bar row) + 10 + 24 (bar row) + 10 (bottom) = 98`.
struct CodeActivityView: View {
    let model: CodeAgentViewModel

    private var stage: Stage { model.visibleStage ?? .thinking }
    private var session: SessionTracker.Session? { model.displayedSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            detail
            CodeUsageBars(model: model, compact: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.startTicking() }
        .onDisappear { model.stopTicking() }
        .codeContextMenu(model)
    }

    private var header: some View {
        HStack(spacing: 6) {
            AgentIcon(agent: model.displayedAgent, size: 18, isPulsing: stage == .thinking)
            // The same animated glyph the compact slot shows, so the card the user expands
            // into is recognizably the one they were watching.
            ActivityGlyph(
                kind: ActivityKind.from(stage: stage, tool: session?.tool),
                size: 12
            )
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

    /// Only ever present when there is something to say. ``CodeAgentViewModel/expandedSize``
    /// asks the same session the same question, so the card is exactly as tall as this.
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
