import Testing
import AppKit
@testable import IslandCore

/// Reduce Motion has to reach the island while the app is running, not only when the
/// window happens to be rebuilt.
@MainActor
struct MotionSettingsTests {
    /// A settings object reading a box we control, on a notification centre of our own.
    private func makeSettings(_ value: Bool) -> (MotionSettings, Box, NotificationCenter) {
        let box = Box(value)
        let centre = NotificationCenter()
        return (MotionSettings(read: { box.value }, centre: centre), box, centre)
    }

    @MainActor final class Box {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    @Test func theSettingStartsAtWhateverTheSystemSays() {
        let (settings, _, _) = makeSettings(true)
        defer { settings.stop() }
        #expect(settings.isReduced)
    }

    @Test func aDisplayOptionsChangeIsPickedUpLive() {
        let (settings, box, centre) = makeSettings(false)
        defer { settings.stop() }
        #expect(!settings.isReduced)

        box.value = true
        centre.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(settings.isReduced)

        // And back again: this is a setting the user toggles, not a one-way door.
        box.value = false
        centre.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!settings.isReduced)
    }

    @Test func aChangeToSomethingElseCostsNothing() {
        // The same notification announces contrast and transparency changes. Re-reading
        // is cheap; re-drawing the island for every one of them would not be.
        let (settings, _, centre) = makeSettings(false)
        defer { settings.stop() }
        centre.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!settings.isReduced)
    }

    @Test func stoppingDetachesTheObserver() {
        let (settings, box, centre) = makeSettings(false)
        settings.stop()
        box.value = true
        centre.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!settings.isReduced)
    }

    @Test func theChoreographyIsAPureFunctionOfTheSetting() {
        #expect(TransitionChoreographer.resolved(isReduced: true) == .reducedMotion)
        #expect(TransitionChoreographer.resolved(isReduced: false) == .standard)
    }
}
