// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IslandCore", targets: ["IslandCore"]),
        .library(name: "NowPlayingShared", targets: ["NowPlayingShared"]),
        .library(name: "NowPlayingClient", targets: ["NowPlayingClient"]),
        .library(name: "MusicFeature", targets: ["MusicFeature"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .target(name: "NowPlayingShared"),
        .target(name: "NowPlayingClient", dependencies: ["NowPlayingShared"]),
        .target(name: "MusicFeature", dependencies: ["IslandCore", "NowPlayingShared", "NowPlayingClient"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "NowPlayingSharedTests", dependencies: ["NowPlayingShared"]),
        .testTarget(name: "NowPlayingClientTests", dependencies: ["NowPlayingClient", "NowPlayingShared"]),
        .testTarget(name: "MusicFeatureTests", dependencies: ["MusicFeature", "IslandCore", "NowPlayingShared"]),
    ],
    swiftLanguageModes: [.v6]
)
