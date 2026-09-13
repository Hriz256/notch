import SwiftUI

public struct PresentationID: Hashable, Sendable, CustomStringConvertible {
    private let raw = UUID()
    public init() {}
    /// Short form for logs and view identities: the first UUID field is plenty to tell
    /// one card from another in a queue that never holds more than a handful.
    public var description: String { String(raw.uuidString.prefix(8)) }
}

public enum Priority: Int, Comparable, Sendable {
    case background = 0
    case activity = 1
    case alert = 2
    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PresentationStyle: Sendable, Equatable {
    case peek
    case expanded
}

/// What a feature asks the island to show. Views are type-erased so IslandCore
/// stays independent of feature modules.
@MainActor
public struct Presentation: Identifiable {
    public let id: PresentationID
    public let featureID: FeatureID
    /// What the card is called in menus. Features set it ("Music", "Code"); while it is
    /// nil the feature id stands in — see ``displayTitle``.
    public var title: String?
    public let priority: Priority
    public let style: PresentationStyle
    public let ttl: Duration?
    public var leading: AnyView
    public var trailing: AnyView
    public var expanded: AnyView?
    public var expandedSize: CGSize
    /// Whether the island draws its stack dots over this card. On by default — the dots
    /// are how the user knows there is more than one card — but a panel that is not a
    /// page of the stack in the user's mind (the Drop Zones cards, which exist only for
    /// the length of a drag) turns them off rather than inviting a swipe mid-drop.
    public var showsStackDots: Bool
    /// How wide each peek slot is for this presentation. The default is the island's
    /// standard slot; a presentation whose slots hold more than a glyph (the HUD's label
    /// and bar) asks for more, and the peek island widens to `notch + 2 × slot`.
    public var peekSlotWidth: CGFloat

    public init(
        id: PresentationID = PresentationID(),
        featureID: FeatureID,
        title: String? = nil,
        priority: Priority,
        style: PresentationStyle,
        ttl: Duration? = nil,
        leading: AnyView,
        trailing: AnyView,
        expanded: AnyView?,
        expandedSize: CGSize = CGSize(width: 390, height: 200),
        showsStackDots: Bool = true,
        peekSlotWidth: CGFloat = IslandLayout.peekSlotWidth
    ) {
        precondition(style == .peek || expanded != nil, "expanded style requires an expanded view")
        self.id = id
        self.featureID = featureID
        self.title = title
        self.priority = priority
        self.style = style
        self.ttl = ttl
        self.leading = leading
        self.trailing = trailing
        self.expanded = expanded
        self.expandedSize = expandedSize
        self.showsStackDots = showsStackDots
        self.peekSlotWidth = peekSlotWidth
    }

    /// The name menus show for this card: the feature-provided title, else the feature id
    /// title-cased, so a feature that has not set one still reads as "Music" or "Code".
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return featureID.rawValue.capitalized
    }
}
