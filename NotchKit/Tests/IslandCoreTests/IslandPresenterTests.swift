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
    title: String? = nil,
    priority: Priority = .background,
    style: PresentationStyle = .peek,
    ttl: Duration? = nil,
    hasExpanded: Bool = true
) -> Presentation {
    Presentation(
        featureID: FeatureID(feature),
        title: title,
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

    /// Hover decides whether the current card is open, never *which* card is current: the
    /// alert stays on top of the background card the pointer is over.
    @Test func hoverNeverOverridesAlert() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation(feature: "music")
        let alert = makePresentation(feature: "devices", priority: .alert, style: .peek)
        p.present(music)
        p.present(alert)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.current?.id == alert.id)
        #expect(p.state == .expanded(alert.id))
    }

    /// An alert that carries an expanded view is the only way to read a waiting-for-you
    /// prompt: the detail lives in the panel, not in the 56 pt peek slot.
    @Test func alertWithExpandedViewCanBeHoverPromoted() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let alert = makePresentation(feature: "code", priority: .alert)
        p.present(alert)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.isHoverPromoted)
        #expect(p.state == .expanded(alert.id))
    }

    @Test func alertWithoutExpandedViewCannotBeHoverPromoted() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let alert = makePresentation(feature: "devices", priority: .alert, hasExpanded: false)
        p.present(alert)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.isHoverPromoted == false)
        #expect(p.state == .peek(alert.id))
    }

    /// A session going from working to waiting-for-you raises the same card to `.alert`;
    /// that must not slam an already-open panel shut under the pointer.
    @Test func arrivingAlertWithExpandedKeepsHoverPromotion() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let background = makePresentation(feature: "code")
        p.present(background)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(background.id))

        let alert = makePresentation(feature: "code", priority: .alert)
        p.present(alert)
        #expect(p.isHoverPromoted)
        #expect(p.state == .expanded(alert.id))
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
        // No expanded view, so hovering the alert cannot open anything.
        let alert = makePresentation(
            feature: "devices", priority: .alert, ttl: .seconds(1), hasExpanded: false)
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

    /// Regression: a track-change style activity peek that carries an expanded view must not
    /// collapse an already hover-expanded background under the pointer, and the panel must come
    /// back on its own when the peek's TTL expires (no hover exit/enter in between).
    @Test func activityPeekWithExpandedKeepsHoverPromotion() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let background = makePresentation(feature: "music", priority: .background)
        p.present(background)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(background.id))

        let peek = makePresentation(feature: "music", priority: .activity, ttl: .seconds(2.5))
        p.present(peek)
        #expect(p.state == .expanded(peek.id))
        #expect(p.isHoverPromoted)

        clock.advance(by: .seconds(2.5))
        #expect(p.state == .expanded(background.id))
        #expect(p.isHoverPromoted)
    }

    // MARK: Card stack

    @Test func cycleWithTwoBackgroundPresentationsPinsTheOther() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        #expect(p.current?.id == b.id)
        p.cycle(.next)
        #expect(p.pinnedID == a.id)
        #expect(p.current?.id == a.id)
        #expect(p.state == .peek(a.id))
    }

    @Test func transientAlertStillWinsOverPin() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        p.cycle(.next)
        #expect(p.current?.id == a.id)

        let alert = makePresentation(feature: "devices", priority: .alert, ttl: .seconds(4))
        p.present(alert)
        #expect(p.current?.id == alert.id)
        // The pin survives the interruption and takes over again once it clears.
        #expect(p.pinnedID == a.id)
        p.dismiss(alert.id)
        #expect(p.current?.id == a.id)
    }

    @Test func dismissingPinnedClearsPin() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        p.cycle(.next)
        #expect(p.pinnedID == a.id)
        p.dismiss(a.id)
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == b.id)
    }

    @Test func cycleWithOnePresentationIsNoOp() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        p.present(a)
        p.cycle(.next)
        p.cycle(.previous)
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == a.id)
    }

    @Test func stackKeepsInsertionOrder() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b", priority: .activity)
        let alert = makePresentation(feature: "devices", priority: .alert, ttl: .seconds(4))
        let c = makePresentation(feature: "c")
        p.present(a)
        p.present(b)
        p.present(alert)
        p.present(c)
        #expect(p.stack.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func cycleWrapsAround() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        let c = makePresentation(feature: "c")
        p.present(a)
        p.present(b)
        p.present(c)
        #expect(p.current?.id == c.id)
        p.cycle(.next)          // c -> a
        #expect(p.current?.id == a.id)
        p.cycle(.previous)      // a -> c
        #expect(p.current?.id == c.id)
        p.cycle(.previous)      // c -> b
        #expect(p.current?.id == b.id)
        p.cycle(.next)          // b -> c
        #expect(p.current?.id == c.id)
    }

    @Test func cycleKeepsHoverPromotion() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(b.id))
        p.cycle(.next)
        #expect(p.state == .expanded(a.id))
        #expect(p.isHoverPromoted)
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

    // MARK: Pinning by id

    @Test func pinSelectsThatCard() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        #expect(p.current?.id == b.id)
        p.pin(a.id)
        #expect(p.pinnedID == a.id)
        #expect(p.current?.id == a.id)
        #expect(p.stackIndex == 0)
    }

    @Test func pinningTheCurrentCardIsIdempotent() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        p.pin(b.id)
        p.pin(b.id)
        #expect(p.pinnedID == b.id)
        #expect(p.current?.id == b.id)
    }

    @Test func pinIgnoresAnUnknownID() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        p.present(a)
        p.pin(PresentationID())
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == a.id)
    }

    @Test func pinIgnoresADismissedCard() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        p.dismiss(a.id)
        p.pin(a.id)
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == b.id)
    }

    /// A *transient* alert is an interruption, not a card: it never enters the stack, so it
    /// cannot be pinned either — the pin would outlive the alert itself.
    @Test func pinIgnoresATransientAlert() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let alert = makePresentation(feature: "devices", priority: .alert, ttl: .seconds(4))
        p.present(a)
        p.present(alert)
        p.pin(alert.id)
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == alert.id)
    }

    /// A sticky alert, though, is a card the feature has merely raised to the top — the
    /// Code feature's waiting-for-you prompt. It is pinnable like any other.
    @Test func pinAcceptsAStickyAlert() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let waiting = makePresentation(feature: "code", priority: .alert)
        p.present(a)
        p.present(waiting)
        #expect(p.stack.map(\.id) == [a.id, waiting.id])
        p.pin(waiting.id)
        #expect(p.pinnedID == waiting.id)
        #expect(p.current?.id == waiting.id)
    }

    @Test func unpinRestoresTheQueueWinner() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        p.pin(a.id)
        #expect(p.current?.id == a.id)
        p.unpin()
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == b.id)
    }

    @Test func unpinWithoutAPinIsNoOp() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a")
        p.present(a)
        p.unpin()
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == a.id)
    }

    @Test func unpinKeepsHoverPromotion() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let a = makePresentation(feature: "a")
        let b = makePresentation(feature: "b")
        p.present(a)
        p.present(b)
        p.pin(a.id)
        p.setHovering(true)
        clock.advance(by: IslandPresenter.hoverEnterDelay)
        #expect(p.state == .expanded(a.id))
        p.unpin()
        #expect(p.state == .expanded(b.id))
    }

    // MARK: Cards menu contents

    /// What the Cards menu lists, in the order it lists it: insertion order, transient
    /// alerts left out, with `stackIndex` marking the row that gets the checkmark.
    @Test func cardsListIsTheStackInInsertionOrder() {
        let p = IslandPresenter(clock: ManualClock())
        let a = makePresentation(feature: "a", title: "Music")
        let b = makePresentation(feature: "b", priority: .activity)
        let alert = makePresentation(feature: "devices", priority: .alert, ttl: .seconds(4))
        let c = makePresentation(feature: "c")
        p.present(a)
        p.present(b)
        p.present(alert)
        p.present(c)
        #expect(p.stack.map(\.id) == [a.id, b.id, c.id])
        #expect(p.stack.map(\.displayTitle) == ["Music", "B", "C"])
        // The activity card outranks both backgrounds, so it is the one marked current.
        #expect(p.selectedIndex == 1)
        p.pin(c.id)
        #expect(p.selectedIndex == 2)
        // The dots, unlike the menu, mark nothing while the transient alert is on screen.
        #expect(p.stackIndex == nil)
    }

    @Test func displayTitlePrefersTheFeatureTitle() {
        let titled = makePresentation(feature: "code", title: "Claude Code")
        #expect(titled.displayTitle == "Claude Code")
        #expect(makePresentation(feature: "music").displayTitle == "Music")
        #expect(makePresentation(feature: "music", title: "").displayTitle == "Music")
    }

    @Test func emptyStackHasNoCurrentIndex() {
        let p = IslandPresenter(clock: ManualClock())
        #expect(p.stack.isEmpty)
        #expect(p.stackIndex == nil)
    }

    // MARK: Music + a busy coding agent
    //
    // The shape the user hit: Spotify queues a `.background` card, a Claude Code session
    // queues one long-lived card it mutates in place on every hook event, and each finished
    // session throws a separate 4 s alert on top.

    /// The pin has to outlast everything a working agent does to the queue.
    @Test func pinSurvivesUpdatesAndTransientAlerts() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation(feature: "music")
        let code = makePresentation(feature: "code", priority: .activity)
        p.present(music)
        p.present(code)
        #expect(p.current?.id == code.id)

        p.cycle(.next)
        #expect(p.current?.id == music.id)

        // A hook event re-renders the code card in place.
        p.update(makePresentation(feature: "code", priority: .activity).withID(code.id))
        #expect(p.pinnedID == music.id)
        #expect(p.current?.id == music.id)

        // A session finishes: its alert takes the island for exactly its ttl.
        let alert = makePresentation(feature: "code", priority: .alert, ttl: .seconds(4))
        p.present(alert)
        #expect(p.current?.id == alert.id)
        #expect(p.pinnedID == music.id)
        clock.advance(by: .seconds(4))
        #expect(p.current?.id == music.id)

        // The agent goes away; the pin is still the user's choice.
        p.dismiss(code.id)
        #expect(p.pinnedID == music.id)
        #expect(p.current?.id == music.id)

        // Only losing the pinned card itself clears the pin.
        p.dismiss(music.id)
        #expect(p.pinnedID == nil)
        #expect(p.current == nil)
    }

    /// A card the feature raised to `.alert` to ask for attention is still a card. Dropping
    /// it out of the stack shrank the stack to one and made ``cycle(_:)`` a silent no-op.
    @Test func stickyAlertStaysInTheStackAndCanBeCycledPast() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation(feature: "music")
        let waiting = makePresentation(feature: "code", priority: .alert)
        p.present(music)
        p.present(waiting)
        #expect(p.stack.count == 2)
        #expect(p.current?.id == waiting.id)

        p.cycle(.next)
        #expect(p.pinnedID == music.id)
        #expect(p.current?.id == music.id)
        #expect(p.state == .peek(music.id))
    }

    /// The stage flip that used to resize the dots on every hook event: `.activity` while
    /// the agent works, `.alert` while it waits, same card throughout.
    @Test func stackSizeIsSteadyAcrossPriorityFlips() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation(feature: "music")
        let code = makePresentation(feature: "code", priority: .activity)
        p.present(music)
        p.present(code)
        p.cycle(.next)

        // Working: the card re-renders as fast as the hooks fire and the pin does not care.
        for _ in 0..<3 {
            p.update(makePresentation(feature: "code", priority: .activity).withID(code.id))
            #expect(p.stack.count == 2)
            #expect(p.pinnedID == music.id)
            #expect(p.current?.id == music.id)
        }

        // …until the agent starts *asking*: the first transition into a sticky alert hands
        // the island over, because a pin must not be able to hide a standing prompt.
        p.update(makePresentation(feature: "code", priority: .alert).withID(code.id))
        #expect(p.stack.count == 2)
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == code.id)
    }

    /// The bug: one swipe to Music, and every later "waiting for you" prompt was invisible
    /// for the rest of the session — the alert lost to the pin and nothing cleared the pin.
    @Test func newStickyAlertUnpins() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation(feature: "music")
        let code = makePresentation(feature: "code", priority: .activity)
        p.present(music)
        p.present(code)
        p.pin(music.id)
        #expect(p.current?.id == music.id)

        p.update(makePresentation(feature: "code", priority: .alert).withID(code.id))
        #expect(p.pinnedID == nil)
        #expect(p.current?.id == code.id)

        // The pin the alert itself carries is left alone: pinning the alerting card and
        // then seeing it alert again is not a reason to take the island off it.
        p.pin(code.id)
        p.update(makePresentation(feature: "code", priority: .activity).withID(code.id))
        p.update(makePresentation(feature: "code", priority: .alert).withID(code.id))
        #expect(p.pinnedID == code.id)
    }

    /// An agent that waits re-renders its prompt on every hook event. Only the transition
    /// into `.alert` unpins; the refreshes behind it must leave the user's choice alone.
    @Test func repeatedAlertUpdateDoesNotUnpin() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation(feature: "music")
        let code = makePresentation(feature: "code", priority: .activity)
        p.present(music)
        p.present(code)

        p.update(makePresentation(feature: "code", priority: .alert).withID(code.id))
        // The user swipes back to Music *while* the agent is waiting.
        p.pin(music.id)
        #expect(p.current?.id == music.id)

        for _ in 0..<5 {
            p.update(makePresentation(feature: "code", priority: .alert).withID(code.id))
            #expect(p.pinnedID == music.id)
            #expect(p.current?.id == music.id)
        }
    }

    /// A transient alert is an interruption, not a page: while it is up the dots mark
    /// nothing, and when it expires the island is back on the card the user pinned.
    @Test func transientAlertMarksNoStackDotAndGivesTheIslandBack() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let music = makePresentation(feature: "music")
        let code = makePresentation(feature: "code", priority: .activity)
        p.present(music)
        p.present(code)
        p.pin(music.id)
        #expect(p.stackIndex == 0)

        let alert = makePresentation(feature: "code", priority: .alert, ttl: .seconds(4))
        p.present(alert)
        #expect(p.current?.id == alert.id)
        #expect(p.isShowingTransientAlert)
        #expect(p.stackIndex == nil)
        // The pin is untouched — it is the transient alert, not a standing request.
        #expect(p.pinnedID == music.id)

        clock.advance(by: .seconds(4))
        #expect(!p.isShowingTransientAlert)
        #expect(p.current?.id == music.id)
        #expect(p.stackIndex == 0)
    }

    /// Cycling still works underneath a transient alert, even though the dots mark nothing.
    @Test func cycleWorksWhileATransientAlertIsUp() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation(feature: "music")
        let code = makePresentation(feature: "code", priority: .activity)
        p.present(music)
        p.present(code)
        p.pin(music.id)
        p.present(makePresentation(feature: "code", priority: .alert, ttl: .seconds(4)))

        p.cycle(.next)
        #expect(p.pinnedID == code.id)
    }

    /// With two cards, both directions land on the other one.
    @Test func bothDirectionsReachTheOtherCardOfTwo() {
        let p = IslandPresenter(clock: ManualClock())
        let music = makePresentation(feature: "music")
        let code = makePresentation(feature: "code", priority: .activity)
        p.present(music)
        p.present(code)
        #expect(p.current?.id == code.id)
        p.cycle(.next)
        #expect(p.current?.id == music.id)
        p.cycle(.next)
        #expect(p.current?.id == code.id)
        p.cycle(.previous)
        #expect(p.current?.id == music.id)
    }

    /// `update` must not restart a running countdown, or an alert the feature re-renders
    /// every second would never expire.
    @Test func updateDoesNotRestartTheTTL() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let alert = makePresentation(feature: "code", priority: .alert, ttl: .seconds(4))
        p.present(alert)
        clock.advance(by: .seconds(3))
        p.update(makePresentation(feature: "code", priority: .alert, ttl: .seconds(4)).withID(alert.id))
        clock.advance(by: .seconds(1))
        #expect(p.current == nil)
    }

    /// Losing the ttl turns an interruption into a card, and it needs the timer cancelled
    /// with it — otherwise the card vanishes out of the stack on the old countdown.
    @Test func updateThatDropsTheTTLCancelsTheTimer() {
        let clock = ManualClock()
        let p = IslandPresenter(clock: clock)
        let alert = makePresentation(feature: "code", priority: .alert, ttl: .seconds(4))
        p.present(alert)
        #expect(p.stack.isEmpty)
        p.update(makePresentation(feature: "code", priority: .alert).withID(alert.id))
        clock.advance(by: .seconds(10))
        #expect(p.stack.map(\.id) == [alert.id])
        #expect(p.current?.id == alert.id)
    }
}

private extension Presentation {
    /// A copy of this presentation under an existing id — what a feature does when it
    /// re-renders its long-lived card in place.
    @MainActor
    func withID(_ id: PresentationID) -> Presentation {
        Presentation(
            id: id,
            featureID: featureID,
            title: title,
            priority: priority,
            style: style,
            ttl: ttl,
            leading: leading,
            trailing: trailing,
            expanded: expanded,
            expandedSize: expandedSize
        )
    }
}
