import CoreGraphics
import Foundation

/// Where the drop-zone cards sit inside the panel the island shows during a drag.
///
/// The geometry lives here, apart from SwiftUI and AppKit, because two very
/// different callers must agree on it to the point: the views place each card at
/// its `frame`, and the invisible drop-catcher window asks `hitTest` which card
/// the cursor is over. Anything computed twice would eventually drift, and a
/// drift here means a drop landing on the wrong zone.
///
/// Coordinates are panel-local with the origin at the **top left**, matching the
/// SwiftUI layout the views use; `hitTest` callers convert the screen cursor
/// into that space before asking.
public struct ZoneLayout: Equatable, Sendable {
    /// The panel's size in points; the island animates to this while zones show.
    public static let panelSize = CGSize(width: 280, height: 140)
    /// Margin between the panel's edge and the cards on every side.
    public static let inset: CGFloat = 14
    /// Horizontal space between neighbouring cards.
    public static let gap: CGFloat = 8
    /// How much the views grow the targeted card; the frame itself is unscaled
    /// so that the hit test stays on the laid-out rects rather than on a
    /// transient animation state.
    public static let targetedScale: CGFloat = 1.02

    /// One card: which zone it stands for, where it goes, and whether the cursor
    /// is currently over it.
    public struct Slot: Equatable, Sendable {
        public var zone: Zone
        public var frame: CGRect
        public var isTargeted: Bool

        public init(zone: Zone, frame: CGRect, isTargeted: Bool) {
            self.zone = zone
            self.frame = frame
            self.isTargeted = isTargeted
        }
    }

    /// The cards left to right, in the order `zones()` produced them.
    public var slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }

    /// Lays `zones` out across `size`, widening the card under the cursor.
    ///
    /// The cards share the content rect's full height and tile it horizontally
    /// with no overlap: each one starts where the previous ended plus `gap`, and
    /// the last ends exactly on the trailing inset. The targeted card takes a
    /// larger share so it reads as the drop target even before the drop — 65 %
    /// of two, 45 % of three — and the rest split what is left evenly. A single
    /// card has no one to take width from, so it always fills the content rect
    /// and targeting only sets the flag the view scales on.
    ///
    /// A `targeted` zone that is not in `zones` is ignored rather than treated
    /// as an error: the zone list can change mid-drag (a stash fills, a setting
    /// flips) a moment before the targeting does, and a stale name must not skew
    /// the widths.
    public static func resolve(
        zones: [Zone],
        targeted: Zone?,
        size: CGSize = panelSize
    ) -> ZoneLayout {
        guard !zones.isEmpty else { return ZoneLayout(slots: []) }

        let count = zones.count
        let targetedIndex = targeted.flatMap { zones.firstIndex(of: $0) }
        let height = size.height - 2 * inset
        let available = size.width - 2 * inset - gap * CGFloat(count - 1)

        var x = inset
        var slots: [Slot] = []
        slots.reserveCapacity(count)
        for (index, zone) in zones.enumerated() {
            let width = available * fraction(index: index, count: count, targetedIndex: targetedIndex)
            slots.append(
                Slot(
                    zone: zone,
                    frame: CGRect(x: x, y: inset, width: width, height: height),
                    isTargeted: index == targetedIndex
                )
            )
            x += width + gap
        }
        return ZoneLayout(slots: slots)
    }

    /// The share of the available width the card at `index` gets.
    private static func fraction(index: Int, count: Int, targetedIndex: Int?) -> CGFloat {
        guard let targetedIndex, count > 1 else { return 1 / CGFloat(count) }
        if count == 2 {
            return index == targetedIndex ? 0.65 : 0.35
        }
        return index == targetedIndex ? 0.45 : 0.275
    }

    /// Which zone contains `point` (panel coordinates, origin top-left), or
    /// `nil` in the gaps and margins.
    ///
    /// Points between cards deliberately hit nothing: a drop released there is
    /// ambiguous, and silently snapping it to the nearer card would move files
    /// the user did not aim at.
    public func hitTest(_ point: CGPoint) -> Zone? {
        slots.first { $0.frame.contains(point) }?.zone
    }
}
