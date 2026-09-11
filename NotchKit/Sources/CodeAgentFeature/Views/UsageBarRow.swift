import SwiftUI
import CodeAgentShared

/// One rate-limit window as a bar with a label underneath: how much is spent, when it
/// rolls over, and whether the current burn rate fits the time left.
///
/// Used twice in the expanded panel (session and weekly). `compact` is the activity
/// panel's variant, where the pace label is dropped to its colored dot to make room
/// for the stage and detail lines above.
struct UsageBarRow: View {
    /// Already formatted by the caller, e.g. `"8% session"`.
    let label: String
    /// `nil` when the provider could not report this window — the bar stays empty.
    let window: UsageWindow?
    let pace: Pace?
    /// Injected rather than read from the clock so the reset countdown is testable
    /// and re-renders exactly when the view model ticks.
    let now: Date
    var compact: Bool = false

    private var fraction: Double {
        guard let window else { return 0 }
        return min(1, max(0, window.percent / 100))
    }

    private var resetText: String? {
        guard let resetsAt = window?.resetsAt else { return nil }
        return "Resets " + ResetFormatter.string(until: resetsAt, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bar
            HStack(spacing: 6) {
                Text(window == nil ? "—" : label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 6)
                if let resetText {
                    Text(resetText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                if let pace {
                    Circle()
                        .fill(Self.paceColor(pace))
                        .frame(width: 6, height: 6)
                    if !compact {
                        Text(Self.paceLabel(pace))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Self.paceColor(pace))
                    }
                }
            }
            .lineLimit(1)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(CodePalette.salmon)
                    .frame(width: geo.size.width * fraction)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 4)
    }

    static func paceColor(_ pace: Pace) -> Color {
        switch pace {
        case .good: CodePalette.green
        case .slowDown: CodePalette.red
        }
    }

    static func paceLabel(_ pace: Pace) -> String {
        switch pace {
        case .good: "You're good"
        case .slowDown: "Slow down"
        }
    }
}
