import SwiftUI

/// The physical notch's size, published to every view the island hosts.
///
/// A feature's *expanded* view sometimes has to reproduce the peek's geometry inside
/// itself — the stash card's hover state keeps its thumbnail and count badge exactly
/// where the peek had them — and `PeekRow` needs the notch's size to do that. The
/// features have no access to `NotchGeometry` (it is resolved from `ScreenMetrics` in
/// the surface layer), so `SurfaceView` puts the number in the environment instead of
/// every feature re-deriving it.
///
/// The default is the 14"/16" MacBook Pro notch, which is what every machine this app
/// targets has; it only ever applies to a view rendered outside `SurfaceView` (a
/// preview, a render test).
public struct NotchSizeKey: EnvironmentKey {
    public static let defaultValue = CGSize(width: 185, height: 32)
}

extension EnvironmentValues {
    /// The notch's size in points, as `SurfaceView` measured it.
    public var notchSize: CGSize {
        get { self[NotchSizeKey.self] }
        set { self[NotchSizeKey.self] = newValue }
    }
}
