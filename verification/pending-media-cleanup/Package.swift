// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PendingMediaCleanupProof",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PendingMediaCleanupProof",
            path: "Sources"),
    ]
)
