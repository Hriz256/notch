import CodeAgentShared

/// The one word the activity panel's header puts a stage in.
///
/// A namespace, not a view: what a stage *looks* like is ``ActivityGlyph``'s business now,
/// and it answers a finer question than ``Stage`` can — "editing" and "running a command"
/// are both `.creating`. Only the wording is shared, so only the wording lives here.
enum StageLabel {
    /// The header line of the activity panel.
    static func title(_ stage: Stage) -> String {
        switch stage {
        case .analyzing: "Analyzing"
        case .thinking: "Thinking"
        case .creating: "Creating"
        case .waiting: "Waiting for you"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }
}
