// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RattlegramCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RattlegramCore", targets: ["RattlegramCore"]),
        .executable(name: "RattlegramCLI", targets: ["RattlegramCLI"]),
    ],
    targets: [
        .target(name: "RattlegramCore", dependencies: [], path: "Sources/RattlegramCore"),
        .executableTarget(name: "RattlegramCLI", dependencies: ["RattlegramCore"], path: "Sources/RattlegramCLI"),
        .testTarget(name: "RattlegramCoreTests", dependencies: ["RattlegramCore"], path: "Tests/RattlegramCoreTests"),
    ]
)
