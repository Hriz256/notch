import SwiftUI
import NowPlayingShared

/// Why the progress fill moved, and therefore how it should get there.
///
/// The view model refreshes `displayedElapsed` once a second — and only while the expanded
/// card is on screen — so on its own the fill steps 1/180th of the bar at a time and reads as
/// a clock rather than as a playhead. The fix is not a faster timer: it is to let the fill
/// *cross* each gap at a constant rate, which costs one animation per second and nothing at
/// rest. That only works if the three reasons the value can change are told apart, hence this
/// pure classification, which is tested rather than eyeballed.
enum ProgressGlide: Equatable {
    /// No motion at all: the value did not move, or it belongs to a different track.
    case cut
    /// The once-a-second tick. The fill runs to the new position at a constant rate, timed to
    /// arrive as the next tick lands.
    case glide
    /// A jump inside the same track — the user scrubbed here, or scrubbed in the source app.
    case seek

    /// How often the view model ticks, and therefore how long a glide has to cover one step.
    static let tickInterval: Double = 1
    /// The largest forward step still attributable to a tick. A late timer or a busy main
    /// thread stretches a second; anything past this is a jump, not a tick.
    static let maxTickStep: TimeInterval = 1.5
    static let seekDuration: Double = 0.2

    /// Everything the classification depends on. `trackID` is what makes a reset to zero a
    /// *cut*: gliding or easing there would run the fill backwards across the whole bar.
    struct Sample: Equatable {
        var elapsed: TimeInterval
        var trackID: String?
    }

    static func classify(from old: Sample, to new: Sample) -> ProgressGlide {
        guard new.trackID == old.trackID else { return .cut }
        let step = new.elapsed - old.elapsed
        if step == 0 { return .cut }
        if step > 0, step <= maxTickStep { return .glide }
        return .seek
    }

    var animation: Animation? {
        switch self {
        case .cut: return nil
        // The one place `linear` is right: a playhead advances at a constant rate, and the
        // audit reserves the curve for exactly that.
        case .glide: return .linear(duration: Self.tickInterval)
        case .seek: return .easeOut(duration: Self.seekDuration)
        }
    }
}

/// Elapsed / remaining labels around a thin seekable bar.
struct TimeProgressBar: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    /// Which track `elapsed` belongs to. A change here resets the fill without animating, so
    /// the bar never runs backwards on a skip.
    var trackID: String?
    var tint: Color = .white
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: Double?
    /// The sample the fill is currently drawn at. Written only from `onChange`, which runs
    /// after `body`, so the value read while building `body` is genuinely the previous one.
    @State private var previous: ProgressGlide.Sample?

    private var sample: ProgressGlide.Sample {
        ProgressGlide.Sample(elapsed: elapsed, trackID: trackID)
    }

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var body: some View {
        // A drag is the user's own hand: it must follow the pointer with no curve at all.
        // Keying the animation on `sample` gets that for free — dragging changes `fraction`
        // without changing `sample`, so no animation is installed.
        let glide = ProgressGlide.classify(from: previous ?? sample, to: sample)
        HStack(spacing: 8) {
            Text(TimeFormatting.mmss(fraction * duration))
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.25))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * fraction)
                        .animation(glide.animation, value: sample)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(1, max(0, v.location.x / geo.size.width)) }
                        .onEnded { v in
                            let f = min(1, max(0, v.location.x / geo.size.width))
                            dragFraction = nil
                            onSeek(f * duration)
                        }
                )
            }
            .frame(height: 12)
            Text("-" + TimeFormatting.mmss(max(0, duration - fraction * duration)))
                .monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(tint.opacity(0.8))
        .onChange(of: sample, initial: true) { _, new in previous = new }
    }
}
