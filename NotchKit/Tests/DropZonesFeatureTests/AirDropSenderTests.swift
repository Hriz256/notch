import AppKit
import Testing
@testable import DropZonesFeature

/// Only the refusal path is testable: a successful `send` opens the system
/// AirDrop sheet, which a test process must never do. The happy path is verified
/// by the user's real drops (see the task report).
@MainActor @Suite struct AirDropSenderTests {

    @Test func sendingNothingIsRefusedWithoutAskingTheSystem() {
        #expect(!AirDropSender.send([]))
    }
}
