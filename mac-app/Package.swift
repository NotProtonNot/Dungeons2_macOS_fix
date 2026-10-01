// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DungeonsFixer",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that touches the disk, the registry or CrossOver. No UI, fully unit tested.
        .target(name: "FixerCore"),
        // The SwiftUI app.
        .executableTarget(name: "DungeonsFixer", dependencies: ["FixerCore"]),
        .testTarget(name: "FixerCoreTests", dependencies: ["FixerCore"]),
    ]
)
