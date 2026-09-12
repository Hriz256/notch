import CodeAgentShared
import SwiftUI

/// The expanded panel while nothing is running: where this week's quota went.
///
/// Height budget — the card is 380 × 170 and the top 32 pt are under the physical notch,
/// so 138 pt are usable:
/// `2 (top) + 18 (header) + 8 + 24 (bar row) + 8 + 24 (bar row) + 8 + 26 (sparkline)
///  + 2 + 13 (caption) + 5 (bottom) = 138`.
struct CodeExpandedView: View {
    let model: CodeAgentViewModel

    /// The notch itself eats the top of the card.
    static let notchPad: CGFloat = 32
    static let usableHeight = CodeAgentViewModel.expandedSize.height - notchPad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            CodeUsageBars(model: model)
            sparkline
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The bars' reset countdown and the activity panel's elapsed clock both come from
        // the model's tick, which only runs while an expanded panel is on screen.
        .onAppear { model.startTicking() }
        .onDisappear { model.stopTicking() }
        .codeContextMenu(model)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentIcon(agent: model.displayedAgent, size: 18)
            Spacer(minLength: 0)
            CaffeinateButton(model: model)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private var sparkline: some View {
        // A week with fewer than two days of data has no shape to draw; the caption would
        // then label an empty rectangle, so both go together.
        if model.sparkline.count >= 2 {
            VStack(alignment: .leading, spacing: 2) {
                SparklineView(values: model.sparkline, height: 26)
                Text("Last 7 days")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

/// Keeps the machine awake while agents work. Filled cup = the assertion is held now.
struct CaffeinateButton: View {
    let model: CodeAgentViewModel

    var body: some View {
        Button {
            model.toggleCaffeinate()
        } label: {
            Image(systemName: model.isCaffeinating ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.isCaffeinating ? CodePalette.salmon : .white.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.caffeinateWhileWorking ? "Stop caffeinating this agent" : "Caffeinate this agent")
        .accessibilityLabel("Caffeinate agent")
    }
}

/// The two rate-limit bars, or the one line that says why there are none.
///
/// Shared by the idle and the activity panel so a stage change cannot make the usage
/// section jump: only `compact` differs, which drops the pace *wording* (not the dot) to
/// buy the activity panel room for its detail line.
struct CodeUsageBars: View {
    let model: CodeAgentViewModel
    var compact: Bool = false

    var body: some View {
        if let error = model.usageError {
            Text(Self.message(for: error))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Reset countdowns are the only thing on this panel that moves on its own, and
            // a minute is the smallest unit they show.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    row(label: Self.label(model.displayedUsage?.session?.percent, "session"),
                        window: model.displayedUsage?.session,
                        now: context.date)
                    row(label: Self.label(model.displayedUsage?.weekly?.percent, "weekly"),
                        window: model.displayedUsage?.weekly,
                        now: context.date)
                }
            }
        }
    }

    private func row(label: String, window: UsageWindow?, now: Date) -> some View {
        UsageBarRow(
            label: label,
            window: window,
            pace: model.pace(for: window),
            now: now,
            isStale: model.isUsageStale(asOf: now),
            compact: compact
        )
    }

    static func label(_ percent: Double?, _ suffix: String) -> String {
        "\(Int((percent ?? 0).rounded()))% \(suffix)"
    }

    /// One sentence per failure, in the user's terms: what to *do*, not what broke.
    static func message(for error: UsageError) -> String {
        switch error {
        case .notSignedIn: "Open Claude Code to sign in"
        case .unavailable(let reason): reason
        case .network, .rateLimited: "Usage temporarily unavailable"
        }
    }
}
