// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIDeliveryVerification",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "StoreProof", path: "Sources/StoreProof"),
        .executableTarget(name: "ReportMediaProof", path: "Sources/ReportMediaProof"),
        .executableTarget(name: "DatabaseProof", path: "Sources/DatabaseProof"),
    ]
)
