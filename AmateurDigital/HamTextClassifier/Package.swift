// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HamTextClassifier",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "HamTextClassifier",
            targets: ["HamTextClassifier"]
        ),
    ],
    targets: [
        .target(
            name: "HamTextClassifier",
            resources: [
                .copy("Resources/HamTextClassifier.mlmodelc"),
            ]
        ),
        .testTarget(
            name: "HamTextClassifierTests",
            dependencies: ["HamTextClassifier"],
            resources: [
                .copy("Resources/golden_test_pairs.json"),
            ]
        ),
    ]
)
