import SwiftUI

public struct PresentationID: Hashable, Sendable {
    private let raw = UUID()
    public init() {}
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
    public let priority: Priority
    public let style: PresentationStyle
    public let ttl: Duration?
    public var leading: AnyView
    public var trailing: AnyView
    public var expanded: AnyView?
    public var expandedSize: CGSize

    public init(
        id: PresentationID = PresentationID(),
        featureID: FeatureID,
        priority: Priority,
        style: PresentationStyle,
        ttl: Duration? = nil,
        leading: AnyView,
        trailing: AnyView,
        expanded: AnyView?,
        expandedSize: CGSize = CGSize(width: 390, height: 200)
    ) {
        precondition(style == .peek || expanded != nil, "expanded style requires an expanded view")
        self.id = id
        self.featureID = featureID
        self.priority = priority
        self.style = style
        self.ttl = ttl
        self.leading = leading
        self.trailing = trailing
        self.expanded = expanded
        self.expandedSize = expandedSize
    }
}
