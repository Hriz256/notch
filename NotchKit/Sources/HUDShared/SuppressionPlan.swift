/// One thing the suppressor does to the system (spec §2 "Suppressing the system HUD").
/// Data rather than calls, so the plan can be tested without touching the system and the
/// executor is the only impure part.
public enum SuppressionStep: Equatable, Sendable {
    /// `EnableSystemBanners` in `com.apple.controlcenter`: `false` hands the OSD back to
    /// `OSDUIHelper`, `nil` removes the key.
    case setBannersPreference(Bool?)
    /// `SIGTERM` to Control Center, which launchd brings straight back — the preference is
    /// read at launch.
    case restartControlCenter
    /// `SIGKILL` to the helper, then `launchctl kickstart gui/<uid>/com.apple.OSDUIHelper`:
    /// a fresh helper, so a stopped one's queued requests die with it instead of replaying.
    case kickstartOSDUIHelper
    /// `SIGSTOP` to the helper: it keeps its launchd slot but never draws.
    case stopOSDUIHelper
}

/// The step lists for suppressing the system HUD, restoring it and repairing it.
public enum SuppressionPlan {
    /// The steps that put the system HUD away.
    ///
    /// - Parameter controlCenterConfigured: the key is already `false` *and* Control Center
    ///   has been restarted since we set it, so it already runs the wanted way and another
    ///   restart would only blink the menu bar. The preference's value alone is not enough:
    ///   an earlier run may have written it and then failed to restart Control Center.
    public static func apply(controlCenterConfigured: Bool) -> [SuppressionStep] {
        var steps: [SuppressionStep] = []
        if !controlCenterConfigured {
            steps += [.setBannersPreference(false), .restartControlCenter]
        }
        steps += [.kickstartOSDUIHelper, .stopOSDUIHelper]
        return steps
    }

    /// The steps that give the system HUD back.
    ///
    /// - Parameter weSetPreference: whether the key is ours to remove. A user who had it
    ///   `false` before Notch keeps it.
    public static func lift(weSetPreference: Bool) -> [SuppressionStep] {
        var steps: [SuppressionStep] = [.kickstartOSDUIHelper]
        if weSetPreference {
            steps += [.setBannersPreference(nil), .restartControlCenter]
        }
        return steps
    }

    /// The watchdog: a helper that is missing or running again gets relaunched and stopped.
    public static func repairIfNeeded(osdHelperStopped: Bool) -> [SuppressionStep] {
        osdHelperStopped ? [] : [.kickstartOSDUIHelper, .stopOSDUIHelper]
    }
}
