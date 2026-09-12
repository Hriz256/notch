/// The only surface a feature sees. Features never touch the window.
@MainActor
public protocol IslandPresenting: AnyObject {
    func present(_ presentation: Presentation)
    func update(_ presentation: Presentation)
    func dismiss(_ id: PresentationID)

    /// Asks for the island window to sit in the user's *active* Space rather than in the
    /// private one it normally lives in.
    ///
    /// The private Space composites above every user Space, which is exactly what keeps
    /// the island out of Space-transition animations — and also what draws it over
    /// Finder's drag image, so a file dragged onto the island disappears behind it. A
    /// feature that needs the drag image on top (Drop Zones, while its cards are up)
    /// asks for the window to come back down into the user Space for the duration, and
    /// hands it back afterwards.
    ///
    /// Default no-op: a feature is never *required* to care, and neither is a presenter.
    func setSurfaceInUserSpace(_ inUserSpace: Bool)
}

public extension IslandPresenting {
    func setSurfaceInUserSpace(_ inUserSpace: Bool) {}
}

@MainActor
public protocol IslandFeature: AnyObject {
    var id: FeatureID { get }
    func activate(presenter: any IslandPresenting)
    func deactivate()
}
