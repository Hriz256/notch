/// The only surface a feature sees. Features never touch the window.
@MainActor
public protocol IslandPresenting: AnyObject {
    func present(_ presentation: Presentation)
    func update(_ presentation: Presentation)
    func dismiss(_ id: PresentationID)
}

@MainActor
public protocol IslandFeature: AnyObject {
    var id: FeatureID { get }
    func activate(presenter: any IslandPresenting)
    func deactivate()
}
