import Testing
import Foundation
import CoreGraphics
import CodeAgentShared
@testable import CodeAgentFeature

@Suite("Code agent leaf views")
@MainActor
struct CodeViewsTests {
    private static let allStages: [Stage] = [.analyzing, .thinking, .creating, .waiting, .completed, .failed]

    @Test("Every stage has a title and a distinct symbol")
    func stageTitles() {
        #expect(StageGlyph.title(.analyzing) == "Analyzing")
        #expect(StageGlyph.title(.thinking) == "Thinking")
        #expect(StageGlyph.title(.creating) == "Creating")
        #expect(StageGlyph.title(.waiting) == "Waiting for you")
        #expect(StageGlyph.title(.completed) == "Done")
        #expect(StageGlyph.title(.failed) == "Failed")

        #expect(StageGlyph.symbol(.waiting) == "hand.raised.fill")
        #expect(StageGlyph.symbol(.completed) == "checkmark")
        // No two stages should be indistinguishable at a glance.
        let symbols = Set(Self.allStages.map(StageGlyph.symbol))
        #expect(symbols.count == Self.allStages.count)
    }

    @Test("The Claude sprite is a well-formed 10 x 8 grid")
    func spriteGrid() {
        #expect(AgentIcon.claudeSprite.count == AgentIcon.spriteRows)
        #expect(AgentIcon.spriteRows == 8)
        #expect(AgentIcon.spriteColumns == 10)
        for row in AgentIcon.claudeSprite {
            #expect(row.count == AgentIcon.spriteColumns)
            #expect(row.allSatisfy { $0 == "#" || $0 == "·" })
        }
        // The eye row is the one with gaps inside an otherwise solid band.
        #expect(AgentIcon.claudeSprite[2] == "##·####·##")
    }

    @Test("Pace labels")
    func paceLabels() {
        #expect(UsageBarRow.paceLabel(.good) == "You're good")
        #expect(UsageBarRow.paceLabel(.slowDown) == "Slow down")
    }

    @Test("Sparkline normalizes to the maximum and needs at least two samples")
    func sparklinePoints() throws {
        let size = CGSize(width: 100, height: 34)
        #expect(SparklineView.points(for: [], in: size) == nil)
        #expect(SparklineView.points(for: [5], in: size) == nil)

        let points = try #require(SparklineView.points(for: [0, 5, 10], in: size))
        #expect(points.count == 3)
        #expect(points[0].x == 0)
        #expect(points[2].x == 100)
        // Largest sample sits highest (smallest y), smallest sits lowest.
        #expect(points[2].y < points[1].y)
        #expect(points[1].y < points[0].y)
    }

    @Test("An all-zero week draws a flat line on the baseline, not a divide by zero")
    func sparklineAllZero() throws {
        let points = try #require(
            SparklineView.points(for: [0, 0, 0, 0, 0, 0, 0], in: CGSize(width: 70, height: 34))
        )
        #expect(points.count == 7)
        let ys = Set(points.map(\.y))
        #expect(ys.count == 1)
        #expect(points[0].y > 33)
    }

    @Test("Catmull-Rom path passes through the samples")
    func smoothPath() {
        let points = [CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 5)]
        let path = SparklineView.smoothPath(through: points)
        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(bounds.minX == 0)
        #expect(bounds.maxX == 20)
    }
}
