import AppKit
import os

/// Hands files to the system's AirDrop sheet.
///
/// Deliberately the whole feature: no `NSSharingServicePicker`, no anchoring, no
/// error alert. Seam does exactly this — ask for the one service, ask whether it
/// can take these items, perform — and a refusal is logged and nothing else,
/// because there is no honest thing to tell the user that the system sheet would
/// not already say.
public enum AirDropSender {

    private static let logger = Logger(subsystem: "app.notch", category: "dropzones.airdrop")

    /// Opens the AirDrop sheet for `urls`; `false` when the system declined,
    /// which leaves the stash and the island untouched.
    @MainActor
    public static func send(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else {
            logger.error("AirDrop asked for with no files")
            return false
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            logger.error("AirDrop sharing service unavailable")
            return false
        }
        guard service.canPerform(withItems: urls) else {
            logger.error("AirDrop cannot send \(urls.count, privacy: .public) file(s)")
            return false
        }
        service.perform(withItems: urls)
        logger.info("AirDrop sheet requested for \(urls.count, privacy: .public) file(s)")
        return true
    }
}
