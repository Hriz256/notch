// swift-tools-version: 6.2
import PackageDescription

// Standalone feasibility spike for the Drop Zones feature. Deliberately NOT part of
// the Xcode project (project.yml does not reference it) so it can never affect the app.
let package = Package(
    name: "DropSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DropSpike",
            path: "Sources/DropSpike",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
