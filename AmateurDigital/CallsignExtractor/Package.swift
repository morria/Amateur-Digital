// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CallsignExtractor",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CallsignExtractor",
            targets: ["CallsignExtractor"]
        ),
    ],
    targets: [
        .target(
            name: "CallsignExtractor",
            resources: [
                .copy("Resources/CallsignModel.mlmodelc"),
            ]
        ),
        .testTarget(
            name: "CallsignExtractorTests",
            dependencies: ["CallsignExtractor"]
        ),
    ]
)
