import Foundation

/// File sizes the way Finder writes them.
public enum ByteFormatting {

    /// "512 bytes", "89 KB", "1.2 MB".
    ///
    /// `.file` is the count style Finder uses — 1 KB is 1000 bytes, not 1024 —
    /// so a file the user just looked at in Finder reads the same size here.
    ///
    /// The formatter is built per call rather than cached in a `static let`:
    /// `ByteCountFormatter` is a mutable reference type and therefore not
    /// `Sendable`, and it is cheap next to the drop it describes.
    public static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// The caption under the stash's hover-expanded card.
public enum StashCaption {

    /// "1 file · 89 KB", "3 files · 1.2 MB".
    ///
    /// The separator is U+00B7 with a space either side, matching the reference.
    public static func text(count: Int, bytes: Int64) -> String {
        let noun = count == 1 ? "file" : "files"
        return "\(count) \(noun) \u{00B7} \(ByteFormatting.fileSize(bytes))"
    }
}

/// The label under a zone card's icon.
public enum ZoneTitle {

    /// The card's title. Only the stash card varies: once something is stashed it
    /// says how much, so the user can see what a `.replace` drop would destroy
    /// before letting go.
    public static func label(_ zone: Zone, fileCount: Int) -> String {
        switch zone {
        case .airDrop:
            "AirDrop"
        case .stash:
            switch fileCount {
            case 0: "File Stash"
            case 1: "1 File"
            default: "\(fileCount) Files"
            }
        case .addToStash:
            "Add to Stash"
        case .replaceStash:
            "Replace Stash"
        }
    }
}
