import SwiftUI
import CodeAgentShared

/// The badge that says which agent the island is currently showing.
///
/// Claude gets a hand-drawn pixel sprite (there is no SF Symbol for it); Codex and
/// Cursor borrow SF Symbols. `isPulsing` fades the whole icon while the agent is
/// thinking.
struct AgentIcon: View {
    let agent: Agent
    var size: CGFloat = 18
    var isPulsing: Bool = false

    @State private var dimmed = false

    /// Whether the icon actually breathes. Reduce Motion keeps it at full opacity: the
    /// pulse says nothing the glyph beside it does not already say, so there is nothing to
    /// replace it with — same rule the activity glyphs follow.
    private var pulses: Bool { isPulsing && !GlyphMotion.isReduced }

    /// Both inputs the opacity depends on, so `.animation(_:value:)` re-evaluates the
    /// moment pulsing stops and replaces the `repeatForever` with a single fade back
    /// to full opacity — see `VisualizerBars` for the same pattern.
    private struct AnimationKey: Equatable {
        let isPulsing: Bool
        let dimmed: Bool
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .opacity(pulses && dimmed ? 0.6 : 1)
            .animation(pulses ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                              : .easeOut(duration: 0.2),
                       value: AnimationKey(isPulsing: pulses, dimmed: dimmed))
            .onAppear { if pulses { dimmed = true } }
            .onChange(of: pulses) { _, pulsing in
                // Clear unanimated first so a resumed pulse always starts from full
                // opacity rather than from the middle of a half-finished cycle.
                withAnimation(nil) { dimmed = false }
                if pulsing { dimmed = true }
            }
            .accessibilityLabel(agent.displayName)
    }

    @ViewBuilder
    private var glyph: some View {
        switch agent {
        case .claude:
            ClaudeSprite(size: size)
        case .codex:
            symbol("terminal.fill")
        case .cursor:
            symbol("cursorarrow.rays")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.78, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
    }
}

/// The Claude pixel creature, drawn cell by cell on a 10 × 8 grid.
///
/// Edit `AgentIcon.claudeSprite` to reshape it — `#` is a lit pixel, `·` is empty.
/// Every row must be exactly `spriteColumns` characters long and there must be
/// exactly `spriteRows` rows (`CodeViewsTests` enforces both).
struct ClaudeSprite: View {
    var size: CGFloat
    var color: Color = CodePalette.salmon

    /// The canvas is the grid's own 10 : 8 shape rather than a square, so the drawing can
    /// never be larger than the box it is given — a square canvas with the sprite centred
    /// inside it looks identical but leaves the `Canvas` free to overflow the 56 pt peek
    /// slot when a parent proposes it more room.
    var body: some View {
        Canvas { context, canvasSize in
            let cell = canvasSize.width / CGFloat(AgentIcon.spriteColumns)
            var path = Path()
            for (row, line) in AgentIcon.claudeSprite.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    path.addRect(
                        CGRect(
                            x: CGFloat(column) * cell,
                            y: CGFloat(row) * cell,
                            width: cell,
                            height: cell
                        )
                    )
                }
            }
            context.fill(path, with: .color(color))
        }
        .frame(width: size, height: size * CGFloat(AgentIcon.spriteRows) / CGFloat(AgentIcon.spriteColumns))
    }
}

extension AgentIcon {
    /// A friendly blocky creature: domed head, two eye gaps, a mouth notch and three
    /// stubby legs. 10 columns × 8 rows.
    static let claudeSprite: [String] = [
        "·########·",
        "##########",
        "##·####·##",
        "##########",
        "#·######·#",
        "·########·",
        "·##·##·##·",
        "·##·##·##·",
    ]

    static let spriteColumns = 10
    static let spriteRows = 8
}
