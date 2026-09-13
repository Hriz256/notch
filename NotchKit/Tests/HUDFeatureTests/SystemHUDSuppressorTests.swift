import Foundation
import HUDShared
import IslandCore
import Testing
@testable import HUDFeature

/// Records the steps and models the two bits of system state the plan depends on.
final class FakeSystemShell: SystemShell, @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [SuppressionStep] = []
    private var _preference: Bool?
    private var _helperStopped = false

    var steps: [SuppressionStep] { lock.withLock { _steps } }
    var preference: Bool? {
        get { lock.withLock { _preference } }
        set { lock.withLock { _preference = newValue } }
    }
    var helperStopped: Bool {
        get { lock.withLock { _helperStopped } }
        set { lock.withLock { _helperStopped = newValue } }
    }

    func bannersPreference() -> Bool? { preference }
    func setBannersPreference(_ value: Bool?) {
        lock.withLock { _preference = value; _steps.append(.setBannersPreference(value)) }
    }
    func restartControlCenter() { lock.withLock { _steps.append(.restartControlCenter) } }
    func kickstartOSDUIHelper() { lock.withLock { _helperStopped = false; _steps.append(.kickstartOSDUIHelper) } }
    func stopOSDUIHelper() -> Bool { lock.withLock { _helperStopped = true; _steps.append(.stopOSDUIHelper) }; return true }
    func isOSDUIHelperStopped() -> Bool { helperStopped }
    func clearSteps() { lock.withLock { _steps.removeAll() } }
}

@MainActor
final class SystemHUDSuppressorTests {
    private let suite: String
    private let defaults: UserDefaults

    init() throws {
        suite = "app.notch.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func make() -> (SystemHUDSuppressor, FakeSystemShell, ManualClock) {
        let shell = FakeSystemShell()
        let clock = ManualClock()
        return (SystemHUDSuppressor(shell: shell, clock: clock, defaults: defaults), shell, clock)
    }

    @Test func applyRunsThePlanAndRecordsTheFlags() async {
        let (suppressor, shell, clock) = make()
        await suppressor.apply()

        #expect(shell.steps == [.setBannersPreference(false), .restartControlCenter, .kickstartOSDUIHelper, .stopOSDUIHelper])
        #expect(suppressor.isApplied)
        #expect(defaults.bool(forKey: "hud.suppressionApplied"))
        #expect(defaults.bool(forKey: "hud.weSetBannersPreference"))
        #expect(clock.pendingCount == 1)   // the watchdog
    }

    @Test func applyWithThePreferenceAlreadyOffLeavesControlCenterAlone() async {
        let (suppressor, shell, _) = make()
        shell.preference = false
        await suppressor.apply()

        #expect(shell.steps == [.kickstartOSDUIHelper, .stopOSDUIHelper])
        #expect(!defaults.bool(forKey: "hud.weSetBannersPreference"))
    }

    @Test func liftRemovesOnlyOurPreference() async {
        let (suppressor, shell, clock) = make()
        await suppressor.apply()
        shell.clearSteps()
        await suppressor.lift()

        #expect(shell.steps == [.kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter])
        #expect(!suppressor.isApplied)
        #expect(!defaults.bool(forKey: "hud.suppressionApplied"))
        #expect(clock.pendingCount == 0)

        let (other, otherShell, _) = make()
        otherShell.preference = false
        await other.apply()
        otherShell.clearSteps()
        await other.lift()
        #expect(otherShell.steps == [.kickstartOSDUIHelper])
        #expect(otherShell.preference == false)
    }

    @Test func liftWhenNotAppliedDoesNothing() async {
        let (suppressor, shell, _) = make()
        await suppressor.lift()
        #expect(shell.steps.isEmpty)
    }

    @Test func watchdogRestopsAHelperThatCameBack() async {
        let (suppressor, shell, clock) = make()
        await suppressor.apply()
        shell.clearSteps()

        clock.advance(by: .seconds(5))
        await suppressor.settle()
        #expect(shell.steps.isEmpty)          // still stopped: nothing to do
        #expect(clock.pendingCount == 1)      // re-armed

        shell.helperStopped = false
        clock.advance(by: .seconds(5))
        await suppressor.settle()
        #expect(shell.steps == [.kickstartOSDUIHelper, .stopOSDUIHelper])
    }

    @Test func repairAtLaunchLiftsALeftoverWhenTheFeatureIsOff() async {
        let (first, _, _) = make()
        await first.apply()

        let (second, shell, _) = make()   // same defaults: a new process after a crash
        #expect(second.isApplied)
        await second.repairAtLaunch(featureWillBeOn: false)
        #expect(shell.steps == [.kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter])
        #expect(!second.isApplied)
    }

    @Test func repairAtLaunchLeavesItToActivateWhenTheFeatureIsOn() async {
        let (first, _, _) = make()
        await first.apply()

        let (second, shell, _) = make()
        await second.repairAtLaunch(featureWillBeOn: true)
        #expect(shell.steps.isEmpty)
        #expect(second.isApplied)
    }

    @Test func liftSynchronouslyRunsOnTheCallingThread() async {
        let (suppressor, shell, _) = make()
        await suppressor.apply()
        shell.clearSteps()
        suppressor.liftSynchronously()
        #expect(shell.steps == [.kickstartOSDUIHelper, .setBannersPreference(nil), .restartControlCenter])
        #expect(!suppressor.isApplied)
    }
}
