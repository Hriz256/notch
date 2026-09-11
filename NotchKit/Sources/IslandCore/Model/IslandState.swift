public enum IslandState: Equatable, Sendable {
    case collapsed
    case peek(PresentationID)
    case expanded(PresentationID)

    public var presentationID: PresentationID? {
        switch self {
        case .collapsed: nil
        case .peek(let id), .expanded(let id): id
        }
    }
}
