// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ModeClassifierModel",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ModeClassifierModel",
            targets: ["ModeClassifierModel"]
        ),
    ],
    targets: [
        .target(
            name: "ModeClassifierModel",
            resources: [.copy("Resources/ModeClassifier.mlmodelc")]
        ),
        .testTarget(
            name: "ModeClassifierModelTests",
            dependencies: ["ModeClassifierModel"]
        ),
    ]
)
