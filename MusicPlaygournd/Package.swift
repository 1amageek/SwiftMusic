// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MusicPlaygournd",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MusicPlaygournd", targets: ["MusicPlaygourndApp"]),
        .library(name: "MusicPlaygourndCore", targets: ["MusicPlaygourndCore"])
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .target(
            name: "MusicPlaygourndCore",
            dependencies: [.product(name: "SwiftMusic", package: "SwiftMusic")],
            exclude: ["DESIGN.md", "Evaluation/DESIGN.md", "Rendering/DESIGN.md", "Playback/DESIGN.md"]
        ),
        .executableTarget(
            name: "MusicPlaygourndApp",
            dependencies: ["MusicPlaygourndCore", .product(name: "SwiftMusic", package: "SwiftMusic")],
            exclude: ["DESIGN.md", "Editor/DESIGN.md"]
        ),
        .testTarget(name: "MusicPlaygourndCoreTests", dependencies: ["MusicPlaygourndCore", "MusicPlaygourndApp"])
    ]
)
