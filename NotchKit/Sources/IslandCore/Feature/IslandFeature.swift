/// The only surface a feature sees. Features never touch the window.
@MainActor
public protocol IslandPresenting: AnyObject {
    func present(_ presentation: Presentation)
    func update(_ presentation: Presentation)
    func dismiss(_ id: PresentationID)

    /// Asks the surface to draw itself from the *mirror* window — the copy that lives in
    /// the ordinary user Space — for as long as `mirrored` is `true`.
    ///
    /// The island normally lives in a private SkyLight Space at absolute level 400, which
    /// composites above the system's drag-image window: the file thumbnail in the user's
    /// hand disappears behind the island. The mirror is an identical window in the user
    /// Space, so the drag image draws on top of it again (see
    /// ``IslandPresenter/setSurfaceMirrored(_:)`` and `SurfaceController`).
    ///
    /// Only Drop Zones asks for this, and only while a file drag is in flight — hence the
    /// no-op default, which keeps every other feature (and every test double) unchanged.
    func setSurfaceMirrored(_ mirrored: Bool)
}

public extension IslandPresenting {
    /// Presenters that own no windows — the test doubles, the previews — have nothing to
    /// mirror.
    func setSurfaceMirrored(_ mirrored: Bool) {}
}

@MainActor
public protocol IslandFeature: AnyObject {
    var id: FeatureID { get }
    func activate(presenter: any IslandPresenting)
    func deactivate()
}
