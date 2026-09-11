import SwiftUI
import CodeAgentShared

/// The one-symbol summary of what a session is doing, used both in the compact
/// island's trailing slot and in the activity panel's header.
///
/// Only the three stages that need the user's attention are colored — waiting amber,
/// done green, failed red — so a colored glyph in the corner of the eye always means
/// "something changed", and the working stages stay quiet white.
struct StageGlyph: View {
    let stage: Stage
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: Self.symbol(stage))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Self.color(stage))
            .accessibilityLabel(Self.title(stage))
    }

    static func symbol(_ stage: Stage) -> String {
        switch stage {
        case .analyzing: "magnifyingglass"
        case .thinking: "ellipsis"
        case .creating: "pencil.line"
        case .waiting: "hand.raised.fill"
        case .completed: "checkmark"
        case .failed: "xmark"
        }
    }

    static func color(_ stage: Stage) -> Color {
        switch stage {
        case .analyzing, .thinking, .creating: .white
        case .waiting: CodePalette.amber
        case .completed: CodePalette.green
        case .failed: CodePalette.red
        }
    }

    /// The header line of the activity panel.
    static func title(_ stage: Stage) -> String {
        switch stage {
        case .analyzing: "Analyzing"
        case .thinking: "Thinking"
        case .creating: "Creating"
        case .waiting: "Waiting for you"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }
}
