// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SoundbrennerPixel",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SoundbrennerPixel"
        ),
        .testTarget(
            name: "SoundbrennerPixelTests",
            dependencies: ["SoundbrennerPixel"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
