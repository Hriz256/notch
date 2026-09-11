import Testing
import SwiftUI
@testable import IslandCore

/// Deterministic clock: actions fire when `advance(by:)` crosses their due time.
@MainActor
final class ManualClock: IslandClock {
    private struct Entry { let due: Duration; let action: @MainActor () -> Void; let id: Int }
    private var entries: [Entry] = []
    private var nextID = 0
    private(set) var now: Duration = .zero

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> ScheduledToken {
        let id = nextID; nextID += 1
        entries.append(Entry(due: now + delay, action: action, id: id))
        return ScheduledToken { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    func advance(by delta: Duration) {
        let target = now + delta
        while let next = entries.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            entries.removeAll { $0.id == next.id }
            next.action()
        }
        now = target
    }
}

@MainActor
private func makePresentation(
    feature: String = "music",
    priority: Priority = .background,
    style: PresentationStyle = .peek,
    ttl: Duration? = nil,
    hasExpanded: Bool = true
) -> Presentation {
    Presentation(
        featureID: FeatureID(feature),
        priority: priority,
        style: style,
        ttl: ttl,
        leading: AnyView(EmptyView()),
        trailing: AnyView(EmptyView()),
        expanded: hasExpanded ? AnyView(EmptyView()) : nil,
        expandedSize: CGSize(width: 390, height: 200)
    )
}

@MainActor
struct IslandPresenterTests {
    @Test func emptyQueueIsCollapsed() {
        let p = IslandPresenter(clock: ManualClock())
        #expect(p.state == .collapsed)
        #expect(p.current == nil)
    }

    @Test func peekPresentationYieldsPeekState() {
        let p = IslandPresenter(clock: ManualClock())
        let pres = makePresentation()
        p.present(pres)
        #expect(p.state == .peek(pres.id))
    }

    @Test func expandedStyleYieldsExpandedState() {
        let p = IslandPresenter(clock: ManualClock())
        let pres = makePresentation(style: .expanded)
        p.present(pres)
        #expect(p.state == .expanded(pres.id))
    }

    @Test func higherPriorityWins() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation(feature: "music", priority: .background)
        let toast = makePresentation(feature: "devices", priority: .alert)
        p.present(music)
        p.present(toast)
        #expect(p.state == .peek(toast.id))
        p.dismiss(toast.id)
        #expect(p.state == .peek(music.id))
    }

    @Test func samePriorityNewestWins() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a", priority: .activity)
        let b = makePresentation(feature: "b", priority: .activity)
        p.present(a)
        p.present(b)
        #expect(p.current?.id == b.id)
    }

    @Test func ttlExpiryRemovesPresentation() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation(feature: "music")
        let peek = makePresentation(feature: "music", priority: .activity, ttl: .seconds(2.5))
        p.present(music)
        p.present(peek)
        #expect(p.state == .peek(peek.id))
        clock.advance(by: .seconds(2.4))
        #expect(p.state == .peek(peek.id))
        clock.advance(by: .seconds(0.2))
        #expect(p.state == .peek(music.id))
    }

    @Test func ttlExpiryOnEmptyQueueCollapses() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        p.present(makePresentation(priority: .alert, ttl: .seconds(3)))
        clock.advance(by: .seconds(3))
        #expect(p.state == .collapsed)
    }

    @Test func updateReplacesContentKeepsPosition() {
        let p = IslandPresenter(clock: ManualClock())
        var pres = makePresentation()
        p.present(pres)
        pres.expandedSize = CGSize(width: 400, height: 220)
        p.update(pres)
        #expect(p.current?.expandedSize.width == 400)
        #expect(p.queue.count == 1)
    }

    @Test func hoverPromotesBackgroundAfterEnterDelay() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation()
        p.present(music)
        p.setHovering(true)
        #expect(p.state == .peek(music.id))
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(music.id))
    }

    @Test func hoverExitDemotesAfterExitDelay() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation()
        p.present(music)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        p.setHovering(false)
        #expect(p.state == .expanded(music.id))
        clock.advance(by: IslandPresenter.hoverExitDelay)
        #expect(p.state == .peek(music.id))
    }

    @Test func hoverCancelledBeforeEnterDelayDoesNothing() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation()
        p.present(music)
        p.setHovering(true)
        p.setHovering(false)
        clock.advance(by: .seconds(5))
        #expect(p.state == .peek(music.id))
    }

    @Test func hoverNeverOverridesAlert() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let alert = makePresentation(feature: "devices", priority: .alert, style: .peek)
        p.present(alert)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .peek(alert.id))
    }

    @Test func hoverDoesNothingWithoutExpandedView() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let pres = makePresentation(hasExpanded: false)
        p.present(pres)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .peek(pres.id))
    }

    @Test func toggleHoverPromotionExpandsAndCollapsesImmediately() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation()
        p.present(music)
        p.toggleHoverPromotion()
        #expect(p.state == .expanded(music.id))
        p.toggleHoverPromotion()
        #expect(p.state == .peek(music.id))
    }

    @Test func hoverSurvivesPresentationSwap() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(a.id))
        p.dismiss(a.id)
        p.present(b)
        #expect(p.state == .peek(b.id))
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(b.id))
    }

    @Test func hoverBeforeFirstPresentDoesNotPromoteInstantly() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        p.setHovering(true)
        clock.advance(by: .seconds(5))
        #expect(p.isHoverPromoted == false)
        let a = makePresentation(feature: "a")
        p.present(a)
        #expect(p.state == .peek(a.id))
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(a.id))
    }

    @Test func hoverOverAlertThenAlertExpiresPromotesBackground() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation(feature: "music")
        let alert = makePresentation(feature: "devices", priority: .alert, ttl: .seconds(1))
        p.present(music)
        p.present(alert)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .peek(alert.id))
        clock.advance(by: .seconds(1))
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(music.id))
    }

    @Test func clickCollapseIsNotUndoneByQueueChange() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let a = makePresentation(feature: "a")
        p.present(a)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(a.id))

        p.toggleHoverPromotion()
        #expect(p.state == .peek(a.id))

        // Queue churn while the pointer never left must not undo the click-collapse.
        p.update(a)
        let b = makePresentation(feature: "b")
        p.present(b)
        clock.advance(by: .seconds(5))
        #expect(p.state == .peek(b.id))

        // Leaving and re-entering re-arms hover promotion normally.
        p.setHovering(false)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(b.id))
    }

    @Test func dismissingCurrentClearsHoverPromotion() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation()
        p.present(music)
        p.toggleHoverPromotion()
        p.dismiss(music.id)
        #expect(p.state == .collapsed)
        #expect(p.isHoverPromoted == false)
    }
}
