import Testing
@testable import DropZonesShared

/// `ByteCountFormatter` output is locale-dependent (the digit group and decimal
/// separators, and the non-breaking space before the unit all vary), so these
/// tests assert on the stable parts — the unit and the digits — rather than on a
/// literal string that would only pass in one region.
@Suite struct FormattingTests {

    // MARK: - ByteFormatting

    @Test func kilobytesUseTheFileCountStyle() {
        // .file counts 1 KB as 1000 bytes, so 89_000 is 89 KB and not 86.9 KB.
        let text = ByteFormatting.fileSize(89_000)
        #expect(text.contains("KB"))
        #expect(text.contains("89"))
    }

    @Test func megabytesAreAbbreviated() {
        let text = ByteFormatting.fileSize(1_200_000)
        #expect(text.contains("MB"))
        #expect(text.contains("1"))
    }

    @Test func smallFilesStayInBytes() {
        let text = ByteFormatting.fileSize(512)
        #expect(text.contains("512"))
        #expect(text.contains("bytes"))
    }

    @Test func zeroBytesFormatsWithoutCrashing() {
        #expect(ByteFormatting.fileSize(0).isEmpty == false)
    }

    // MARK: - StashCaption

    @Test func captionIsSingularForOneFile() {
        let text = StashCaption.text(count: 1, bytes: 89_000)
        #expect(text.hasPrefix("1 file · "))
        #expect(text.contains("KB"))
    }

    @Test func captionIsPluralForSeveralFiles() {
        let text = StashCaption.text(count: 3, bytes: 1_200_000)
        #expect(text.hasPrefix("3 files · "))
        #expect(text.contains("MB"))
    }

    @Test func captionIsPluralForZeroFiles() {
        #expect(StashCaption.text(count: 0, bytes: 0).hasPrefix("0 files · "))
    }

    @Test func captionUsesAMiddleDotSeparator() {
        // U+00B7 with a space either side — the separator the reference uses.
        #expect(StashCaption.text(count: 1, bytes: 1).contains(" \u{00B7} "))
    }

    // MARK: - ZoneTitle

    @Test func anEmptyStashZoneIsNamedFileStash() {
        #expect(ZoneTitle.label(.stash, fileCount: 0) == "File Stash")
    }

    @Test func aStashZoneWithFilesCountsThem() {
        #expect(ZoneTitle.label(.stash, fileCount: 1) == "1 File")
        #expect(ZoneTitle.label(.stash, fileCount: 3) == "3 Files")
    }

    @Test func theOtherZoneTitlesIgnoreTheFileCount() {
        #expect(ZoneTitle.label(.airDrop, fileCount: 0) == "AirDrop")
        #expect(ZoneTitle.label(.airDrop, fileCount: 3) == "AirDrop")
        #expect(ZoneTitle.label(.addToStash, fileCount: 3) == "Add to Stash")
        #expect(ZoneTitle.label(.replaceStash, fileCount: 3) == "Replace Stash")
    }
}
