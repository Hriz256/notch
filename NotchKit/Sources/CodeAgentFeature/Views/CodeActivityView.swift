import CodeAgentShared
import IslandCore
import SwiftUI

/// The expanded panel while a session is running, waiting or has just finished.
///
/// The same 380 × 170 card as ``CodeExpandedView``, carrying the same two usage bars, the
/// same sparkline and the same coffee cup: opening the island while an agent works must
/// not cost the user the numbers they opened it for, and a card that changed size as the
/// session moved between stages made the island twitch.
///
/// Height budget (170 pt card, 32 pt of it under the notch, so 138 pt usable):
/// `2 (top) + 18 (header) + 8 + 24 (bar row) + 8 + 24 (bar row) + 8 + 22 (sparkline)
///  + 2 + 13 (caption) + 5 (bottom) = 134`.
///
/// A detail line (a permission prompt, the last assistant message) takes the sparkline's
/// place rather than the card's remaining 4 pt: two 11 pt lines and their spacing are
/// 34 pt, which the 37 pt sparkline block pays for exactly.
struct CodeActivityView: View {
    let model: CodeAgentViewModel

    /// The notch itself eats the top of the card.
    static let usableHeight = CodeAgentViewModel.expandedSize.height - CodeExpandedView.notchPad

    private var stage: Stage { model.visibleStage ?? .thinking }
    private var session: SessionTracker.Session? { model.displayedSession }
    private var detailText: String? {
        guard let text = session?.detail, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let detailText { detail(detailText) }
            CodeUsageBars(model: model, compact: true)
            // Dropped whenever there is a detail line: the two do not both fit, and a
            // prompt the user has to answer outranks last week's shape.
            if detailText == nil { sparkline }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.startTicking() }
        .onDisappear { model.stopTicking() }
        .codeContextMenu(model)
    }

    /// Baseline-aligned, not centre-aligned: the 13 pt title, the 11 pt tool name and the
    /// 11 pt clock differ enough in cap height that centring them left the small text
    /// floating, and the glyphs — which have no baseline of their own — are pinned to the
    /// same line by hand.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AgentIcon(agent: model.displayedAgent, size: 18, isPulsing: model.visibleActivity == .thinking)
                .glyphBaseline(height: 18, textSize: 13)
            // Literally the glyph the compact slot is showing — the same smoothed value,
            // not a second derivation of it — so expanding the island never swaps the mark
            // the user was watching for a different one.
            ActivityGlyph(kind: model.visibleActivity, size: 12)
                .glyphBaseline(height: ActivityGlyph.boxHeight(for: 12), textSize: 13)
            Text(StageLabel.title(stage))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if let tool = session?.tool, !tool.isEmpty {
                Text(tool)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 6)
            CaffeinateButton(model: model)
                .glyphBaseline(height: CaffeinateButton.height, textSize: 11)
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

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            // Amber is the island's "this needs you" colour; everywhere else the
            // detail is just context and stays quiet.
            .foregroundStyle(stage == .waiting ? CodePalette.amber : .white.opacity(0.7))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two points shorter than the idle panel's graph, which is what the header's tool
    /// name and clock cost. Same caption, so the two panels still read as one card.
    @ViewBuilder
    private var sparkline: some View {
        if model.sparkline.count >= 2 {
            VStack(alignment: .leading, spacing: 2) {
                SparklineView(values: model.sparkline, height: 22)
                Text("Last 7 days")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

extension View {
    /// Puts a glyph that has no text baseline of its own onto the baseline of the text
    /// beside it, by claiming one where its optical centre would sit.
    ///
    /// A symbol reads as level with a word when its middle lines up with the word's
    /// x-height middle, which is about 0.3 × the type size above the baseline — so the
    /// baseline the glyph reports is that far below its own centre. Without this, SwiftUI
    /// falls back to the glyph's bottom edge and the small symbols ride up.
    func glyphBaseline(height: CGFloat, textSize: CGFloat) -> some View {
        alignmentGuide(.firstTextBaseline) { _ in height / 2 + textSize * 0.3 }
    }
}
