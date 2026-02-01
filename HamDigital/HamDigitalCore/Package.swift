// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HamDigitalCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "HamDigitalCore",
            targets: ["HamDigitalCore"]
        ),
        .executable(
            name: "GenerateTestAudio",
            targets: ["GenerateTestAudio"]
        ),
    ],
    targets: [
        .target(
            name: "HamDigitalCore",
            dependencies: [],
            path: "Sources/HamDigitalCore"
        ),
        .executableTarget(
            name: "GenerateTestAudio",
            dependencies: ["HamDigitalCore"],
            path: "Sources/GenerateTestAudio"
        ),
        .testTarget(
            name: "HamDigitalCoreTests",
            dependencies: ["HamDigitalCore"],
            path: "Tests/HamDigitalCoreTests"
        ),
    ]
)
