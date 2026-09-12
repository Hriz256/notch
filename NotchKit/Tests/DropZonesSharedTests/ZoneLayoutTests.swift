import CoreGraphics
import Testing
@testable import DropZonesShared

/// The 65/35 and 45/27.5/27.5 splits produce non-integer widths, so frames are
/// compared with a tolerance rather than with `==` on `CGRect`.
private func expectFrame(
    _ slot: ZoneLayout.Slot,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(slot.frame.origin.x - x) < 0.001, "x", sourceLocation: sourceLocation)
    #expect(abs(slot.frame.origin.y - y) < 0.001, "y", sourceLocation: sourceLocation)
    #expect(abs(slot.frame.width - width) < 0.001, "width", sourceLocation: sourceLocation)
    #expect(abs(slot.frame.height - height) < 0.001, "height", sourceLocation: sourceLocation)
}

/// Content rect of the 280×140 panel: 14 pt in at the sides and the bottom, 34 pt at
/// the top so the cards clear the notch — (14, 34, 252, 92).
private let contentX: CGFloat = 14
private let contentY: CGFloat = 34
private let contentWidth: CGFloat = 252
private let cardHeight: CGFloat = 92
/// Right edge every layout must end on, whatever the split.
private let contentMaxX: CGFloat = 266

@Suite struct ZoneLayoutTests {

    // MARK: - Constants

    @Test func constantsMatchTheVisualSpec() {
        #expect(ZoneLayout.panelSize == CGSize(width: 280, height: 140))
        #expect(ZoneLayout.inset == 14)
        // The notch's 32 pt plus the 2 pt of black under it the reference frames show.
        #expect(ZoneLayout.topInset == 34)
        #expect(ZoneLayout.contentRect == CGRect(x: 14, y: 34, width: 252, height: 92))
        #expect(ZoneLayout.gap == 8)
        #expect(ZoneLayout.targetedScale == 1.02)
    }

    // MARK: - Untargeted layouts

    @Test func emptyZonesProduceNoSlots() {
        #expect(ZoneLayout.resolve(zones: [], targeted: nil).slots.isEmpty)
    }

    @Test func singleZoneFillsTheContentRect() {
        let layout = ZoneLayout.resolve(zones: [.stash], targeted: nil)
        #expect(layout.slots.count == 1)
        #expect(layout.slots[0].zone == .stash)
        #expect(layout.slots[0].isTargeted == false)
        expectFrame(layout.slots[0], x: contentX, y: contentY, width: contentWidth, height: cardHeight)
    }

    @Test func twoZonesUntargetedSplitFiftyFifty() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: nil)
        #expect(layout.slots.map(\.zone) == [.airDrop, .stash])
        #expect(layout.slots.allSatisfy { !$0.isTargeted })
        // available = 252 − 8 = 244 → 122 each.
        expectFrame(layout.slots[0], x: 14, y: 34, width: 122, height: 92)
        expectFrame(layout.slots[1], x: 144, y: 34, width: 122, height: 92)
    }

    @Test func threeZonesUntargetedSplitInThirds() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash, .addToStash], targeted: nil)
        #expect(layout.slots.map(\.zone) == [.airDrop, .stash, .addToStash])
        #expect(layout.slots.allSatisfy { !$0.isTargeted })
        // available = 252 − 16 = 236 → 78.6667 each.
        let width = 236.0 / 3.0
        expectFrame(layout.slots[0], x: 14, y: 34, width: width, height: 92)
        expectFrame(layout.slots[1], x: 14 + width + 8, y: 34, width: width, height: 92)
        expectFrame(layout.slots[2], x: 14 + 2 * (width + 8), y: 34, width: width, height: 92)
        #expect(abs(layout.slots[2].frame.maxX - contentMaxX) < 0.001)
    }

    // MARK: - Targeted layouts

    @Test func singleZoneIgnoresTargetingAndStaysFullWidth() {
        // With one card there is nothing to take width from, so targeting only
        // flips the flag the view uses for the 1.02 scale.
        let layout = ZoneLayout.resolve(zones: [.stash], targeted: .stash)
        #expect(layout.slots[0].isTargeted)
        expectFrame(layout.slots[0], x: contentX, y: contentY, width: contentWidth, height: cardHeight)
    }

    @Test func twoZonesTargetingTheFirstSplitsSixtyFiveThirtyFive() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: .airDrop)
        #expect(layout.slots.map(\.isTargeted) == [true, false])
        // 0.65 · 244 = 158.6, 0.35 · 244 = 85.4.
        expectFrame(layout.slots[0], x: 14, y: 34, width: 158.6, height: 92)
        expectFrame(layout.slots[1], x: 180.6, y: 34, width: 85.4, height: 92)
        #expect(abs(layout.slots[1].frame.maxX - contentMaxX) < 0.001)
    }

    @Test func twoZonesTargetingTheSecondSplitsThirtyFiveSixtyFive() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: .stash)
        #expect(layout.slots.map(\.isTargeted) == [false, true])
        expectFrame(layout.slots[0], x: 14, y: 34, width: 85.4, height: 92)
        expectFrame(layout.slots[1], x: 107.4, y: 34, width: 158.6, height: 92)
        #expect(abs(layout.slots[1].frame.maxX - contentMaxX) < 0.001)
    }

    @Test func threeZonesTargetingTheFirstGivesItFortyFivePercent() {
        let layout = ZoneLayout.resolve(
            zones: [.airDrop, .stash, .addToStash], targeted: .airDrop)
        #expect(layout.slots.map(\.isTargeted) == [true, false, false])
        // 0.45 · 236 = 106.2, 0.275 · 236 = 64.9.
        expectFrame(layout.slots[0], x: 14, y: 34, width: 106.2, height: 92)
        expectFrame(layout.slots[1], x: 128.2, y: 34, width: 64.9, height: 92)
        expectFrame(layout.slots[2], x: 201.1, y: 34, width: 64.9, height: 92)
        #expect(abs(layout.slots[2].frame.maxX - contentMaxX) < 0.001)
    }

    @Test func threeZonesTargetingTheSecondGivesItFortyFivePercent() {
        let layout = ZoneLayout.resolve(
            zones: [.airDrop, .stash, .addToStash], targeted: .stash)
        #expect(layout.slots.map(\.isTargeted) == [false, true, false])
        expectFrame(layout.slots[0], x: 14, y: 34, width: 64.9, height: 92)
        expectFrame(layout.slots[1], x: 86.9, y: 34, width: 106.2, height: 92)
        expectFrame(layout.slots[2], x: 201.1, y: 34, width: 64.9, height: 92)
        #expect(abs(layout.slots[2].frame.maxX - contentMaxX) < 0.001)
    }

    @Test func threeZonesTargetingTheThirdGivesItFortyFivePercent() {
        let layout = ZoneLayout.resolve(
            zones: [.airDrop, .stash, .addToStash], targeted: .addToStash)
        #expect(layout.slots.map(\.isTargeted) == [false, false, true])
        expectFrame(layout.slots[0], x: 14, y: 34, width: 64.9, height: 92)
        expectFrame(layout.slots[1], x: 86.9, y: 34, width: 64.9, height: 92)
        expectFrame(layout.slots[2], x: 159.8, y: 34, width: 106.2, height: 92)
        #expect(abs(layout.slots[2].frame.maxX - contentMaxX) < 0.001)
    }

    @Test func targetingAZoneThatIsNotShownLaysOutAsUntargeted() {
        // The targeted zone can lag a zone list that just changed; a stale name
        // must not skew the widths or light up a card.
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: .replaceStash)
        #expect(layout.slots.allSatisfy { !$0.isTargeted })
        expectFrame(layout.slots[0], x: 14, y: 34, width: 122, height: 92)
        expectFrame(layout.slots[1], x: 144, y: 34, width: 122, height: 92)
    }

    // MARK: - Tiling

    @Test func cardsNeverOverlapAndAreSeparatedByTheGap() {
        for targeted: Zone? in [nil, .airDrop, .stash, .addToStash] {
            let layout = ZoneLayout.resolve(
                zones: [.airDrop, .stash, .addToStash], targeted: targeted)
            for (left, right) in zip(layout.slots, layout.slots.dropFirst()) {
                #expect(abs(right.frame.minX - (left.frame.maxX + ZoneLayout.gap)) < 0.001)
            }
        }
    }

    // MARK: - Hit testing

    @Test func hitTestFindsEachCardOfATwoZonePanel() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: nil)
        #expect(layout.hitTest(CGPoint(x: 75, y: 70)) == .airDrop)
        #expect(layout.hitTest(CGPoint(x: 205, y: 70)) == .stash)
    }

    @Test func hitTestFindsEachCardOfAThreeZonePanel() {
        let layout = ZoneLayout.resolve(
            zones: [.airDrop, .stash, .addToStash], targeted: nil)
        for slot in layout.slots {
            #expect(layout.hitTest(CGPoint(x: slot.frame.midX, y: slot.frame.midY)) == slot.zone)
        }
    }

    @Test func hitTestInTheGapBetweenCardsIsNil() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: nil)
        // The gap spans x 136..<144; its midpoint belongs to neither card.
        #expect(layout.hitTest(CGPoint(x: 140, y: 70)) == nil)
    }

    @Test func hitTestInTheInsetMarginsIsNil() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: nil)
        #expect(layout.hitTest(CGPoint(x: 6, y: 70)) == nil)      // left inset
        #expect(layout.hitTest(CGPoint(x: 274, y: 70)) == nil)    // right inset
        #expect(layout.hitTest(CGPoint(x: 140, y: 6)) == nil)     // top inset
        #expect(layout.hitTest(CGPoint(x: 140, y: 134)) == nil)   // bottom inset
    }

    @Test func theNotchBandBelongsToNoCard() {
        // The panel's top 34 pt are the hardware and the 2 pt of black under it: a
        // card that started at the side inset would have its first 18 pt invisible,
        // and a drop released on the notch would land on a zone nobody could see.
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: nil)
        #expect(layout.hitTest(CGPoint(x: 75, y: 20)) == nil)
        #expect(layout.hitTest(CGPoint(x: 75, y: 33)) == nil)
        #expect(layout.hitTest(CGPoint(x: 75, y: 40)) == .airDrop)
    }

    @Test func hitTestOutsideThePanelIsNil() {
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: nil)
        #expect(layout.hitTest(CGPoint(x: -20, y: 70)) == nil)
        #expect(layout.hitTest(CGPoint(x: 400, y: 70)) == nil)
        #expect(layout.hitTest(CGPoint(x: 75, y: -10)) == nil)
        #expect(layout.hitTest(CGPoint(x: 75, y: 300)) == nil)
    }

    @Test func hitTestOnAnEmptyLayoutIsNil() {
        let layout = ZoneLayout.resolve(zones: [], targeted: nil)
        #expect(layout.hitTest(CGPoint(x: 140, y: 70)) == nil)
    }

    @Test func hitTestRespectsTheWiderTargetedCard() {
        // The targeted card grows over ground the other card held a moment ago,
        // so the hit test must follow the resolved widths, not the even split.
        let layout = ZoneLayout.resolve(zones: [.airDrop, .stash], targeted: .airDrop)
        #expect(layout.hitTest(CGPoint(x: 150, y: 70)) == .airDrop)
        #expect(layout.hitTest(CGPoint(x: 200, y: 70)) == .stash)
    }

    // MARK: - Custom panel size

    @Test func resolveHonoursACustomSize() {
        let layout = ZoneLayout.resolve(
            zones: [.airDrop, .stash], targeted: nil, size: CGSize(width: 380, height: 200))
        // available = 380 − 28 − 8 = 344 → 172 each; height = 200 − 34 − 14 = 152.
        expectFrame(layout.slots[0], x: 14, y: 34, width: 172, height: 152)
        expectFrame(layout.slots[1], x: 194, y: 34, width: 172, height: 152)
        #expect(ZoneLayout.contentRect(for: CGSize(width: 380, height: 200))
            == CGRect(x: 14, y: 34, width: 352, height: 152))
    }
}
