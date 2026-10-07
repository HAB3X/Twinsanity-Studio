// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TwinsanityStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CTCore", targets: ["CTCore"]),
        .library(name: "CTParsers", targets: ["CTParsers"]),
        .library(name: "CTModels", targets: ["CTModels"]),
        .library(name: "CTExport", targets: ["CTExport"]),
        .executable(name: "TwinsanityStudio", targets: ["CTStudioApp"]),
    ],
    targets: [
        // MARK: - Core: binary I/O, endianness, generic chunk system
        .target(
            name: "CTCore",
            path: "Sources/CTCore"
        ),

        // MARK: - Models: plain-data representations of parsed assets
        .target(
            name: "CTModels",
            dependencies: ["CTCore"],
            path: "Sources/CTModels"
        ),

        // MARK: - Parsers: BD/BH, RM2/SM2, Texture, Model/Skin/BlendSkin, GraphicsInfo, Animation
        .target(
            name: "CTParsers",
            dependencies: ["CTCore", "CTModels"],
            path: "Sources/CTParsers"
        ),

        // MARK: - Export: PNG/OBJ export, archive repackaging
        .target(
            name: "CTExport",
            dependencies: ["CTCore", "CTModels", "CTParsers"],
            path: "Sources/CTExport"
        ),

        // MARK: - App: SwiftUI IDE shell
        .executableTarget(
            name: "CTStudioApp",
            dependencies: ["CTCore", "CTModels", "CTParsers", "CTExport"],
            path: "Sources/CTStudioApp",
            resources: [.copy("Resources/AppIcon.png")]
        ),

        // MARK: - Tests
        .testTarget(
            name: "CTCoreTests",
            dependencies: ["CTCore"],
            path: "Tests/CTCoreTests"
        ),
        .testTarget(
            name: "CTParsersTests",
            dependencies: ["CTCore", "CTModels", "CTParsers"],
            path: "Tests/CTParsersTests"
        ),
        .testTarget(
            name: "CTExportTests",
            dependencies: ["CTCore", "CTModels", "CTParsers", "CTExport"],
            path: "Tests/CTExportTests"
        ),
        .testTarget(
            name: "CTStudioAppTests",
            dependencies: ["CTCore", "CTModels", "CTParsers", "CTExport", "CTStudioApp"],
            path: "Tests/CTStudioAppTests"
        )
    ]
)
