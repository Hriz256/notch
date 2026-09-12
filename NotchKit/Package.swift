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
        .library(name: "DropZonesShared", targets: ["DropZonesShared"]),
        .library(name: "DropZonesFeature", targets: ["DropZonesFeature"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .target(name: "NowPlayingShared"),
        .target(name: "NowPlayingClient", dependencies: ["NowPlayingShared"]),
        .target(name: "MusicFeature", dependencies: ["IslandCore", "NowPlayingShared", "NowPlayingClient"]),
        .target(name: "CodeAgentShared"),
        .target(name: "CodeAgentFeature", dependencies: ["IslandCore", "CodeAgentShared"]),
        .target(name: "DropZonesShared"),
        .target(name: "DropZonesFeature", dependencies: ["IslandCore", "DropZonesShared"]),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
        .testTarget(name: "NowPlayingSharedTests", dependencies: ["NowPlayingShared"]),
        .testTarget(name: "NowPlayingClientTests", dependencies: ["NowPlayingClient", "NowPlayingShared"]),
        .testTarget(name: "MusicFeatureTests", dependencies: ["MusicFeature", "IslandCore", "NowPlayingShared", "NowPlayingClient"]),
        .testTarget(name: "CodeAgentSharedTests", dependencies: ["CodeAgentShared"]),
        .testTarget(name: "CodeAgentFeatureTests", dependencies: ["CodeAgentFeature", "IslandCore", "CodeAgentShared"]),
        .testTarget(name: "DropZonesSharedTests", dependencies: ["DropZonesShared"]),
        .testTarget(name: "DropZonesFeatureTests", dependencies: ["DropZonesFeature", "IslandCore", "DropZonesShared"]),
    ],
    swiftLanguageModes: [.v6]
)
