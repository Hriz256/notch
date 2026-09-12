import Testing
import Foundation
import CoreGraphics
import CodeAgentShared
@testable import CodeAgentFeature

/// The pure decisions the composed island views make: what a slot says, and whether the
/// idle panel still fits under the notch.
@Suite("Code agent composed views")
@MainActor
struct CodeComposedViewsTests {

    @Test("Bar labels round the percentage and name their window")
    func barLabels() {
        #expect(CodeUsageBars.label(8.4, "session") == "8% session")
        #expect(CodeUsageBars.label(8.6, "session") == "9% session")
        #expect(CodeUsageBars.label(62, "weekly") == "62% weekly")
        // No snapshot yet: the row still reads as a window at 0 rather than as an error.
        #expect(CodeUsageBars.label(nil, "weekly") == "0% weekly")
    }

    @Test("Every usage failure has a one-line, actionable message")
    func errorMessages() {
        #expect(CodeUsageBars.message(for: .notSignedIn) == "Open Claude Code to sign in")
        #expect(CodeUsageBars.message(for: .unavailable("Codex CLI not found")) == "Codex CLI not found")
        #expect(CodeUsageBars.message(for: .unavailable("Sign in to Cursor")) == "Sign in to Cursor")
        #expect(CodeUsageBars.message(for: .network("timed out")) == "Usage temporarily unavailable")
        #expect(CodeUsageBars.message(for: .rateLimited(retryAfter: 60)) == "Usage temporarily unavailable")
    }

    @Test("Hook menu titles name the agent and its state")
    func hookTitles() {
        #expect(CodeContextMenu.hookTitle(.claude, .installed) == "Claude Code — Hooks: Installed")
        #expect(CodeContextMenu.hookTitle(.codex, .notInstalled) == "Codex — Hooks: Not installed")
        #expect(CodeContextMenu.hookTitle(.cursor, nil) == "Cursor — Hooks: Not installed")
        #expect(
            CodeContextMenu.hookTitle(.claude, .failed("~/.claude/settings.json is not valid JSON"))
                == "Claude Code — ~/.claude/settings.json is not valid JSON"
        )
    }

    /// The idle panel is laid out to an exact budget; this is the arithmetic that budget
    /// is written against, so a change to the card size or the notch pad fails here rather
    /// than silently clipping the sparkline caption.
    @Test("The idle panel's rows fit the usable height under the notch")
    func idleLayoutBudget() {
        #expect(CodeExpandedView.usableHeight == 138)

        let padding: CGFloat = 2 + 5
        let header: CGFloat = 18
        let barRow: CGFloat = 4 + 5 + 15   // bar + spacing + 12 pt label line
        let sparkline: CGFloat = 26 + 2 + 13  // graph + spacing + 10 pt caption
        let spacings: CGFloat = 8 * 3
        let total = padding + header + barRow * 2 + sparkline + spacings
        #expect(total <= CodeExpandedView.usableHeight)
    }

    /// The working panel is the same card and carries the same sparkline, so it is laid
    /// out against the same budget — and a detail line only fits in the sparkline's place.
    @Test("The working panel fits, with either the sparkline or a detail line")
    func activityLayoutBudget() {
        #expect(CodeActivityView.usableHeight == CodeExpandedView.usableHeight)

        let padding: CGFloat = 2 + 5
        let header: CGFloat = 18
        let barRow: CGFloat = 4 + 5 + 15      // bar + spacing + 12 pt label line
        let sparkline: CGFloat = 22 + 2 + 13  // graph + spacing + 10 pt caption
        let detail: CGFloat = 13 * 2          // two 11 pt lines
        let bars = padding + header + barRow * 2 + 8 * 2

        #expect(bars + sparkline + 8 <= CodeActivityView.usableHeight)
        #expect(bars + detail + 8 <= CodeActivityView.usableHeight)
        // The two together are exactly what does not fit, which is why one replaces the other.
        #expect(bars + sparkline + detail + 8 * 2 > CodeActivityView.usableHeight)
    }
}
