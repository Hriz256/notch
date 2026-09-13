/// One thing the suppressor does to the system (spec §2 "Suppressing the system HUD").
/// Data rather than calls, so the plan can be tested without touching the system and the
/// executor is the only impure part.
public enum SuppressionStep: Equatable, Sendable {
    /// `EnableSystemBanners` in `com.apple.controlcenter`: `false` hands the OSD back to
    /// `OSDUIHelper`, `nil` removes the key.
    case setBannersPreference(Bool?)
    /// `launchctl kickstart -k gui/<uid>/com.apple.controlcenter` — the preference is read
    /// at launch.
    case restartControlCenter
    /// `launchctl kickstart -k gui/<uid>/com.apple.OSDUIHelper`: a fresh helper, so a
    /// stopped one's queued requests die with it instead of replaying.
    case kickstartOSDUIHelper
    /// `SIGSTOP` to the helper: it keeps its launchd slot but never draws.
    case stopOSDUIHelper
}

/// The step lists for suppressing the system HUD, restoring it and repairing it.
public enum SuppressionPlan {
    /// The steps that put the system HUD away.
    ///
    /// - Parameter preferenceAlreadyFalse: the key is already `false` (we set it on an
    ///   earlier run, or the user did): Control Center already runs the wanted way and a
    ///   restart would only blink the menu bar.
    public static func apply(preferenceAlreadyFalse: Bool) -> [SuppressionStep] {
        var steps: [SuppressionStep] = []
        if !preferenceAlreadyFalse {
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
