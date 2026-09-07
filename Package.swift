// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "SwiftMusic",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftMusic", targets: ["SwiftMusic"])
    ],
    targets: [
        .target(
            name: "SwiftMusic",
            path: "Sources/SwiftMusic",
            exclude: ["DESIGN.md", "ScoreComposition/DESIGN.md"]
        ),
        .testTarget(
            name: "SwiftMusicTests",
            dependencies: ["SwiftMusic"],
            path: "Tests/SwiftMusicTests"
        )
    ]
)
