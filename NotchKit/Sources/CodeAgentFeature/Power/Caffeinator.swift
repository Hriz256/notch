import Foundation
import IOKit.pwr_mgt
import os

/// Holds an IOKit power assertion while coding agents are working.
///
/// `PreventUserIdleSystemSleep` keeps the *machine* awake but still lets the display
/// sleep — the `caffeinate -i` behaviour, which is what a background agent needs.
/// This is deliberately the API, not the `caffeinate(8)` binary: no child process to
/// leak, and the assertion dies with the app.
@MainActor
@Observable
public final class Caffeinator {
    public private(set) var isActive = false

    @ObservationIgnored private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    @ObservationIgnored private let logger = Logger.caffeinate

    public init() {}

    /// Idempotent: setting the state it is already in does nothing.
    public func set(_ on: Bool) {
        guard on != isActive else { return }
        on ? acquire() : release()
    }

    private func acquire() {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Notch: coding agent working" as CFString,
            &id
        )
        guard status == kIOReturnSuccess else {
            logger.error("could not create power assertion (\(status, privacy: .public))")
            return
        }
        assertionID = id
        isActive = true
    }

    private func release() {
        let status = IOPMAssertionRelease(assertionID)
        if status != kIOReturnSuccess {
            logger.error("could not release power assertion (\(status, privacy: .public))")
        }
        assertionID = IOPMAssertionID(0)
        isActive = false
    }
}

private extension Logger {
    static let caffeinate = Logger(subsystem: "app.notch", category: "code.power.caffeinate")
}
