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
        .library(name: "CodeAgentShared", targets: ["CodeAgentShared"]),
        .library(name: "CodeAgentFeature", targets: ["CodeAgentFeature"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .target(name: "NowPlayingShared"),
        .target(name: "NowPlayingClient", dependencies: ["NowPlayingShared"]),
        .target(name: "MusicFeature", dependencies: ["IslandCore", "NowPlayingShared", "NowPlayingClient"]),
        .target(name: "CodeAgentShared"),
        .target(name: "CodeAgentFeature", dependencies: ["IslandCore", "CodeAgentShared"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "NowPlayingSharedTests", dependencies: ["NowPlayingShared"]),
        .testTarget(name: "NowPlayingClientTests", dependencies: ["NowPlayingClient", "NowPlayingShared"]),
        .testTarget(name: "MusicFeatureTests", dependencies: ["MusicFeature", "IslandCore", "NowPlayingShared", "NowPlayingClient"]),
        .testTarget(name: "CodeAgentSharedTests", dependencies: ["CodeAgentShared"]),
        .testTarget(name: "CodeAgentFeatureTests", dependencies: ["CodeAgentFeature", "IslandCore", "CodeAgentShared"]),
    ],
    swiftLanguageModes: [.v6]
)
