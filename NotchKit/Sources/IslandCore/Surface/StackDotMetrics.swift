import CoreGraphics

/// Where the island's page indicator sits and how big it is.
///
/// The dots are a vertical track of dim circles with one bright marker drawn over them,
/// so the marker can *travel* between pages and grow as it lands — the confirmation a
/// swipe needs. Keeping the arithmetic here, rather than inline in the view, is what lets
/// "the marker is always concentric with the dot it marks" be a test rather than a hope.
enum StackDotMetrics {
    /// Diameter of a dot in the track.
    static let size: CGFloat = 3
    /// Diameter of the marker. One point larger: page indicators everywhere in the system
    /// differ in size, not only in opacity.
    static let activeSize: CGFloat = 4
    static let spacing: CGFloat = 5
    static let dimOpacity: Double = 0.35

    /// Centre-to-centre distance between two dots.
    static var stride: CGFloat { size + spacing }

    /// The marker's diameter. Reduce Motion keeps it the size of a plain dot: with no
    /// travel to watch, a growing dot is just another thing moving.
    static func activeDiameter(isReduced: Bool) -> CGFloat {
        isReduced ? size : activeSize
    }

    /// Offset from the top of the track to the top of the marker, chosen so the marker is
    /// concentric with dot `index` whatever its diameter.
    static func activeOffset(index: Int, isReduced: Bool) -> CGFloat {
        CGFloat(index) * stride + (size - activeDiameter(isReduced: isReduced)) / 2
    }

    /// Centre of dot `index`, measured from the top of the track.
    static func dotCentre(index: Int) -> CGFloat {
        CGFloat(index) * stride + size / 2
    }
}
