import Testing
@testable import DropZonesShared

/// Builds a state with the shipped defaults so each test names only what it varies.
private func state(
    airdrop: Bool = true,
    stash: Bool = true,
    secondZone: Bool = false,
    stashDropAction: StashDropAction = .add,
    stashHasFiles: Bool = false,
    isDragOut: Bool = false
) -> ZoneState {
    ZoneState(
        airdrop: airdrop,
        stash: stash,
        secondZone: secondZone,
        stashDropAction: stashDropAction,
        stashHasFiles: stashHasFiles,
        isDragOut: isDragOut
    )
}

@Suite struct ZoneStateTests {

    // MARK: - Two zones

    @Test func bothEnabledWithEmptyStashShowsTwoZones() {
        #expect(state().zones() == [.airDrop, .stash])
    }

    @Test func secondZoneWithEmptyStashStillShowsTwoZones() {
        // With nothing stashed there is nothing to add to or replace, so the
        // third card would be a no-op: it stays hidden until the stash fills.
        #expect(state(secondZone: true).zones() == [.airDrop, .stash])
    }

    // MARK: - The third zone offers the *other* action

    @Test func secondZoneWithFilesAndReplaceDefaultOffersAddToStash() {
        let zones = state(secondZone: true, stashDropAction: .replace, stashHasFiles: true).zones()
        #expect(zones == [.airDrop, .stash, .addToStash])
    }

    @Test func secondZoneWithFilesAndAddDefaultOffersReplaceStash() {
        let zones = state(secondZone: true, stashDropAction: .add, stashHasFiles: true).zones()
        #expect(zones == [.airDrop, .stash, .replaceStash])
    }

    @Test func secondZoneNeedsTheStashZoneItself() {
        // The third card is a second stash action; without the stash card it has no meaning.
        let zones = state(stash: false, secondZone: true, stashHasFiles: true).zones()
        #expect(zones == [.airDrop])
    }

    // MARK: - Single zone and none

    @Test func airDropOffLeavesOnlyTheStash() {
        #expect(state(airdrop: false).zones() == [.stash])
    }

    @Test func stashOffLeavesOnlyAirDrop() {
        #expect(state(stash: false).zones() == [.airDrop])
    }

    @Test func nothingEnabledShowsNoZones() {
        #expect(state(airdrop: false, stash: false).zones().isEmpty)
    }

    // MARK: - Drag out

    @Test func dragOutShowsOnlyTheStashRegardlessOfTheRest() {
        // A drag that started from our own stash can only go back where it came
        // from: AirDrop and the second action are suppressed for that drag.
        let zones = state(secondZone: true, stashHasFiles: true, isDragOut: true).zones()
        #expect(zones == [.stash])
    }

    @Test func dragOutWithTheStashZoneDisabledShowsNothing() {
        // No stash zone means no stash to drag out of, so there is nothing to draw.
        #expect(state(stash: false, isDragOut: true).zones().isEmpty)
    }

    // MARK: - Value semantics

    @Test func zoneRawValuesAreStableForCoding() {
        #expect(Zone.airDrop.rawValue == "airDrop")
        #expect(Zone.stash.rawValue == "stash")
        #expect(Zone.addToStash.rawValue == "addToStash")
        #expect(Zone.replaceStash.rawValue == "replaceStash")
        #expect(Zone.allCases.count == 4)
    }

    @Test func stashDropActionRawValuesMatchTheSettingsKeyValues() {
        // These strings are what `dropzones.stashDropAction` stores in UserDefaults.
        #expect(StashDropAction.replace.rawValue == "replace")
        #expect(StashDropAction.add.rawValue == "add")
    }
}
