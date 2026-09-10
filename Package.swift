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
            exclude: [
                "DESIGN.md",
                "Automation/DESIGN.md",
                "Compilation/DESIGN.md",
                "LiveUpdates/DESIGN.md",
                "MusicalValues/DESIGN.md",
                "Patterns/DESIGN.md",
                "Performance/DESIGN.md",
                "RenderPlan/DESIGN.md",
                "SoundComposition/DESIGN.md",
                "SoundComposition/Modifiers/DESIGN.md",
                "SoundComposition/Sources/DESIGN.md"
            ]
        ),
        .testTarget(
            name: "SwiftMusicTests",
            dependencies: ["SwiftMusic"],
            path: "Tests/SwiftMusicTests"
        )
    ]
)
