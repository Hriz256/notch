import Foundation
import HUDShared
import IslandCore
import Observation
import SwiftUI
import os

/// Builds the two peek slots. Injected so the view model is testable without SwiftUI.
public struct HUDViewFactory {
    public var leading: (HUDViewModel) -> AnyView
    public var trailing: (HUDViewModel) -> AnyView

    public init(
        leading: @escaping (HUDViewModel) -> AnyView,
        trailing: @escaping (HUDViewModel) -> AnyView
    ) {
        self.leading = leading
        self.trailing = trailing
    }
}

/// Turns monitor readings into island presentations (spec §2 "What is shown", "Timing").
///
/// Every reading is delivered with `present(_:)`: on an existing id the presenter replaces
/// the presentation *and re-arms its TTL*, which is exactly the "1.5 s after the last
/// change" the spec asks for. `update(_:)` would leave the countdown alone and is never
/// used here. The view model mirrors that lifetime with its own hold timer so it knows when
/// the HUD is gone and the next change gets a fresh id.
@MainActor
@Observable
public final class HUDViewModel {
    public static let featureID = FeatureID("hud")
    /// What the presentation is called in menus (it is never a card, but the id has a name).
    public static let displayTitle = "HUD"
    public static let holdDuration = HUDSession.holdDuration
    /// The label and the bar do not fit the island's 56 pt slots; the HUD asks for these.
    public static let peekSlotWidth: CGFloat = 96

    /// What the views draw. The last reading survives the hold — the presentation is still
    /// animating out and the bar must not drain to 0 on the way — and only ``stop()`` clears it.
    public private(set) var reading: HUDReading?

    @ObservationIgnored private let presenter: any IslandPresenting
    @ObservationIgnored private let clock: any IslandClock
    @ObservationIgnored private let viewFactory: HUDViewFactory
    @ObservationIgnored private let logger = Logger(subsystem: "app.notch", category: "hud.viewmodel")
    @ObservationIgnored private var session = HUDSession()
    @ObservationIgnored private var presentationID: PresentationID?
    @ObservationIgnored private var holdToken: ScheduledToken?
    @ObservationIgnored private var isStopped = false

    public init(presenter: any IslandPresenting, clock: any IslandClock, viewFactory: HUDViewFactory) {
        self.presenter = presenter
        self.clock = clock
        self.viewFactory = viewFactory
    }

    /// A value that must not show: the level at registration, or after a device switch.
    public func baseline(_ reading: HUDReading) {
        guard !isStopped else { return }
        session.baseline(reading)
    }

    public func receive(_ reading: HUDReading) {
        guard !isStopped else { return }
        switch session.receive(reading) {
        case .none:
            return
        case .present(let shown):
            log("present", shown)
            self.reading = shown
            present(fresh: true)
        case .update(let shown):
            self.reading = shown
            present(fresh: false)
        case .replace(let shown):
            log("replace", shown)
            if let presentationID { presenter.dismiss(presentationID) }
            self.reading = shown
            present(fresh: true)
        }
    }

    /// Dismisses whatever is up and ignores everything after. Called by the feature on
    /// deactivate; a monitor callback that lands late is dropped by `isStopped`.
    public func stop() {
        isStopped = true
        holdToken?.cancel()
        holdToken = nil
        if let presentationID { presenter.dismiss(presentationID) }
        presentationID = nil
        _ = session.expire()
        reading = nil
    }

    // MARK: - Private

    private func present(fresh: Bool) {
        let id = fresh ? PresentationID() : (presentationID ?? PresentationID())
        presentationID = id
        presenter.present(makePresentation(id: id))
        holdToken?.cancel()
        holdToken = clock.schedule(after: Self.holdDuration) { [weak self] in self?.expire() }
    }

    /// The presenter's TTL takes the HUD down at the same moment; dismissing here as well
    /// costs nothing and keeps this side deterministic.
    ///
    /// `reading` is left alone: the presentation fades out over the next frames and a nil
    /// here would drain the bar to 0 while it is still on screen.
    private func expire() {
        holdToken = nil
        _ = session.expire()
        if let presentationID { presenter.dismiss(presentationID) }
        presentationID = nil
        logger.debug("expire")
    }

    private func log(_ verb: String, _ reading: HUDReading) {
        logger.info("\(verb, privacy: .public) \(reading.kind.rawValue, privacy: .public) \(reading.level, privacy: .public)")
    }

    private func makePresentation(id: PresentationID) -> Presentation {
        Presentation(
            id: id,
            featureID: Self.featureID,
            title: Self.displayTitle,
            priority: .alert,
            style: .peek,
            ttl: Self.holdDuration,
            leading: viewFactory.leading(self),
            trailing: viewFactory.trailing(self),
            expanded: nil,
            showsStackDots: false,
            peekSlotWidth: Self.peekSlotWidth
        )
    }
}
