// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DigiModesCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DigiModesCore",
            targets: ["DigiModesCore"]
        ),
        .executable(
            name: "GenerateTestAudio",
            targets: ["GenerateTestAudio"]
        ),
    ],
    targets: [
        .target(
            name: "DigiModesCore",
            dependencies: [],
            path: "Sources/DigiModesCore"
        ),
        .executableTarget(
            name: "GenerateTestAudio",
            dependencies: ["DigiModesCore"],
            path: "Sources/GenerateTestAudio"
        ),
        .testTarget(
            name: "DigiModesCoreTests",
            dependencies: ["DigiModesCore"],
            path: "Tests/DigiModesCoreTests"
        ),
    ]
)
