/// The only surface a feature sees. Features never touch the window.
@MainActor
public protocol IslandPresenting: AnyObject {
    func present(_ presentation: Presentation)
    func update(_ presentation: Presentation)
    func dismiss(_ id: PresentationID)

    /// Asks the island to draw nothing but the bare notch for a while, whatever is in
    /// the queue.
    ///
    /// The island window lives in a private Space that composites above every user
    /// Space — including Finder's drag-image window — so anything it draws covers the
    /// thumbnail the user is dragging, and moving the window out of that Space for the
    /// duration does not change that (measured on macOS 26.5). A feature that has to own
    /// the notch during a drag therefore draws its own panel in an ordinary-Space window
    /// and suppresses the island underneath it, so the two black shapes never both
    /// appear over the notch.
    ///
    /// Suppression hides; it does not dismiss. The queue is untouched, so whatever was
    /// on screen comes back the moment the flag is cleared.
    ///
    /// Default no-op: a feature is never *required* to care, and neither is a presenter.
    func setSurfaceSuppressed(_ suppressed: Bool)
}

public extension IslandPresenting {
    func setSurfaceSuppressed(_ suppressed: Bool) {}
}

@MainActor
public protocol IslandFeature: AnyObject {
    var id: FeatureID { get }
    func activate(presenter: any IslandPresenting)
    func deactivate()
}
