import SwiftUI

/// The "Cards" part of a menu: one row per card in the stack, a checkmark on the one the
/// island is currently showing, and "Unpin" once the user has picked one.
///
/// It is a standalone public view rather than a modifier because a right-click can only
/// ever open *one* menu — the innermost `.contextMenu` under the pointer — and the feature
/// views cover nearly all of the island with their own. Features embed this section into
/// their menu so the cards are reachable from wherever the user right-clicks; `SurfaceView`
/// attaches it to the black shape itself, which is what the user hits in the gaps the
/// feature content leaves (the notch cutout between the peek slots, the margins of an
/// expanded panel).
///
/// `Toggle` is deliberately not used: inside a menu it renders without a visible state on
/// some macOS versions, whereas an explicit checkmark label always reads.
public struct CardsMenuSection: View {
    private let presenter: IslandPresenter?
    private let includesHeader: Bool

    /// - Parameter includesHeader: draws the "Cards" section header. Off when the caller
    ///   already labels the rows, e.g. a `Menu("Cards")` in the status-bar menu.
    public init(presenter: IslandPresenter, includesHeader: Bool = true) {
        self.presenter = presenter
        self.includesHeader = includesHeader
    }

    /// For features, which only ever see the presenter through ``IslandPresenting``.
    ///
    /// The card stack is not part of that protocol — adding it would force every test
    /// double to grow a queue it has no use for — so the concrete type is recovered here
    /// instead. Anything else (a stub in a feature's tests) renders nothing, which is the
    /// honest answer: there is no island, so there are no cards.
    public init(presenter: any IslandPresenting, includesHeader: Bool = true) {
        self.presenter = presenter as? IslandPresenter
        self.includesHeader = includesHeader
    }

    public var body: some View {
        if let presenter {
            if includesHeader {
                Section("Cards") { rows(presenter) }
            } else {
                rows(presenter)
            }
        }
    }

    @ViewBuilder
    private func rows(_ presenter: IslandPresenter) -> some View {
        let stack = presenter.stack
        let index = presenter.stackIndex
        if stack.isEmpty {
            Button("No cards") {}
                .disabled(true)
        } else {
            ForEach(Array(stack.enumerated()), id: \.element.id) { position, card in
                checkmarked(card.displayTitle, isOn: position == index) {
                    presenter.pin(card.id)
                }
            }
        }
        if presenter.pinnedID != nil {
            Divider()
            Button("Unpin") { presenter.unpin() }
        }
    }

    /// A menu row that shows its state as a leading checkmark.
    @ViewBuilder
    private func checkmarked(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
