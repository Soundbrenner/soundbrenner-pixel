// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Mediaforge",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Mediaforge"
        ),
        .testTarget(
            name: "MediaforgeTests",
            dependencies: ["Mediaforge"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
