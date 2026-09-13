import Foundation
import HUDShared
import IslandCore
import os

/// The system calls the suppressor makes, behind a protocol so tests use a fake. Every
/// method blocks (`launchctl`, `proc_listpids`), so callers keep them off the main actor.
public protocol SystemShell: AnyObject, Sendable {
    /// `EnableSystemBanners` in `com.apple.controlcenter`, or `nil` when unset.
    func bannersPreference() -> Bool?
    func setBannersPreference(_ value: Bool?)
    /// Restarts Control Center so it re-reads the preference. `false` if that could not be
    /// done (no process, or the signal was refused), which leaves it running the old way.
    @discardableResult func restartControlCenter() -> Bool
    func kickstartOSDUIHelper()
    /// `SIGSTOP` to the helper. `false` if no helper process could be found.
    func stopOSDUIHelper() -> Bool
    func isOSDUIHelperStopped() -> Bool
}

/// Keeps the system's own volume and brightness HUD off screen while ours is on
/// (spec §2 "Suppressing the system HUD").
///
/// State lives in `UserDefaults` from the moment a change is *about* to be made, so a
/// process that dies mid-way leaves a record for ``repairAtLaunch(featureWillBeOn:)``.
/// Operations are serialised: a toggle that flips twice quickly runs apply, then lift, in
/// order, never interleaved.
@MainActor
public final class SystemHUDSuppressor {
    public static let watchdogInterval: Duration = .seconds(5)
    public static let appliedKey = "hud.suppressionApplied"
    public static let weSetPreferenceKey = "hud.weSetBannersPreference"
    /// Control Center has been restarted since the preference became `false`, so it is really
    /// running the wanted way. Written only after the restart step has run: the preference's
    /// own value proves nothing, an earlier run could have written it and failed to restart.
    public static let controlCenterConfiguredKey = "hud.controlCenterConfigured"

    public private(set) var isApplied: Bool

    private let shell: any SystemShell
    private let clock: any IslandClock
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.notch", category: "hud.suppressor")
    private var watchdog: ScheduledToken?
    private var chain: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Set by ``liftSynchronously()``. Cancelling the chain cannot interrupt a detached step, so
    /// every queued operation checks this and gives up rather than re-suppressing on the way out.
    private var isTerminating = false

    public init(shell: any SystemShell, clock: any IslandClock, defaults: UserDefaults = .standard) {
        self.shell = shell
        self.clock = clock
        self.defaults = defaults
        isApplied = defaults.bool(forKey: Self.appliedKey)
    }

    // MARK: - Operations

    public func apply() async {
        await enqueue { [self] in
            let shell = shell
            let alreadyFalse = await offMain { shell.bannersPreference() == false }
            guard !isTerminating else { return }
            let weSet = defaults.bool(forKey: Self.weSetPreferenceKey) || !alreadyFalse
            let configured = alreadyFalse && defaults.bool(forKey: Self.controlCenterConfiguredKey)
            defaults.set(true, forKey: Self.appliedKey)
            defaults.set(weSet, forKey: Self.weSetPreferenceKey)
            isApplied = true
            let restarted = await execute(SuppressionPlan.apply(controlCenterConfigured: configured))
            guard !isTerminating else { return }
            // Only a restart that actually happened proves Control Center re-read the key.
            if !configured, restarted { defaults.set(true, forKey: Self.controlCenterConfiguredKey) }
            logger.info("system HUD suppressed")
            armWatchdog()
        }
    }

    public func lift() async {
        await enqueue { [self] in
            guard !isTerminating, isApplied else { return }
            cancelWatchdog()
            let weSet = defaults.bool(forKey: Self.weSetPreferenceKey)
            await execute(SuppressionPlan.lift(weSetPreference: weSet))
            clearFlags(controlCenterRestarted: weSet)
            logger.info("system HUD restored")
        }
    }

    /// For `applicationWillTerminate`, where nothing can be awaited: runs the lift on the
    /// calling thread (a few seconds at most) so the system HUD is back before the process ends.
    ///
    /// An `apply()` that is already in flight cannot be interrupted — its steps run detached —
    /// so ``isTerminating`` is set first and the apply abandons itself at its next checkpoint.
    /// The lift also runs off the recorded flag, not just ``isApplied``, so an apply that got as
    /// far as writing the flags is still undone.
    public func liftSynchronously() {
        isTerminating = true
        cancelWatchdog()
        chain?.cancel()
        chain = nil
        guard isApplied || defaults.bool(forKey: Self.appliedKey) else { return }
        let weSet = defaults.bool(forKey: Self.weSetPreferenceKey)
        for step in SuppressionPlan.lift(weSetPreference: weSet) {
            Self.perform(step, on: shell)
        }
        clearFlags(controlCenterRestarted: weSet)
        logger.info("system HUD restored at termination")
    }

    /// Once per launch, before the registry activates anything: a suppression left behind
    /// by a crash is lifted when the feature will not be on to re-apply it.
    ///
    /// A helper can also be left stopped with no record of it — a crash between the `SIGSTOP`
    /// and the flag write, or a termination that raced an apply — so with no flag to go on the
    /// helper itself is asked. Relaunching it is safe either way; the preference is not ours to
    /// touch here, since only a recorded suppression proves we set it.
    public func repairAtLaunch(featureWillBeOn: Bool) async {
        guard !featureWillBeOn else { return }
        if isApplied {
            logger.info("lifting a suppression left over from an earlier run")
            await lift()
            return
        }
        await enqueue { [self] in
            let shell = shell
            guard await offMain({ shell.isOSDUIHelperStopped() }) else { return }
            logger.notice("OSDUIHelper was left stopped with no record of it; relaunching it")
            await execute([.kickstartOSDUIHelper])
        }
    }

    /// Test hook: waits for the queued operations and any running watchdog check.
    func settle() async {
        await chain?.value
        await watchdogTask?.value
    }

    // MARK: - Private

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        chain = task
        await task.value
    }

    /// - Returns: whether every `.restartControlCenter` step in `steps` succeeded — vacuously
    ///   `true` when there was none. A failing step never stops the ones after it.
    @discardableResult
    private func execute(_ steps: [SuppressionStep]) async -> Bool {
        let shell = shell
        return await offMain {
            var restarted = true
            for step in steps where !Self.perform(step, on: shell) { restarted = false }
            return restarted
        }
    }

    /// `nonisolated` because it runs both on the main thread (``liftSynchronously()``) and
    /// off it (``execute(_:)``).
    ///
    /// - Returns: `false` only for a `.restartControlCenter` that did not happen; every other
    ///   step reports `true` (a missing helper is logged where it is noticed instead).
    @discardableResult
    private nonisolated static func perform(_ step: SuppressionStep, on shell: any SystemShell) -> Bool {
        switch step {
        case .setBannersPreference(let value): shell.setBannersPreference(value)
        case .restartControlCenter: return shell.restartControlCenter()
        case .kickstartOSDUIHelper: shell.kickstartOSDUIHelper()
        case .stopOSDUIHelper:
            if !shell.stopOSDUIHelper() {
                Logger(subsystem: "app.notch", category: "hud.suppressor").error("OSDUIHelper not found after kickstart")
            }
        }
        return true
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) { work() }.value
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = clock.schedule(after: Self.watchdogInterval) { [weak self] in self?.watchdogFired() }
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// The check and its repair go through ``enqueue(_:)`` like every other operation: a `lift()`
    /// queued first makes the `isApplied` guard fail, and one queued after runs only when the
    /// repair is done, so it can never leave a stopped helper behind.
    private func watchdogFired() {
        guard isApplied else { return }
        watchdogTask = Task { @MainActor [weak self] in
            await self?.enqueue { [weak self] in
                guard let self, !isTerminating, isApplied else { return }
                let shell = shell
                let stopped = await offMain { shell.isOSDUIHelperStopped() }
                guard !isTerminating, isApplied else { return }
                let steps = SuppressionPlan.repairIfNeeded(osdHelperStopped: stopped)
                if !steps.isEmpty {
                    logger.notice("OSDUIHelper came back; stopping it again")
                    await execute(steps)
                    guard !isTerminating, isApplied else { return }
                }
                armWatchdog()
            }
        }
    }

    /// - Parameter controlCenterRestarted: the lift removed the preference and restarted
    ///   Control Center, so what we knew about its configuration no longer holds. A
    ///   kickstart-only lift (the user's own preference, not ours) leaves that knowledge
    ///   intact — Control Center still runs the way it was last restarted.
    private func clearFlags(controlCenterRestarted: Bool) {
        isApplied = false
        defaults.set(false, forKey: Self.appliedKey)
        defaults.set(false, forKey: Self.weSetPreferenceKey)
        if controlCenterRestarted { defaults.set(false, forKey: Self.controlCenterConfiguredKey) }
    }
}
