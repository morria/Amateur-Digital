// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RattlegramCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RattlegramCore", targets: ["RattlegramCore"]),
        .executable(name: "RattlegramCLI", targets: ["RattlegramCLI"]),
        .executable(name: "RattlegramBenchmark", targets: ["RattlegramBenchmark"]),
    ],
    targets: [
        .target(name: "RattlegramCore", dependencies: [], path: "Sources/RattlegramCore"),
        .executableTarget(name: "RattlegramCLI", dependencies: ["RattlegramCore"], path: "Sources/RattlegramCLI"),
        .executableTarget(name: "RattlegramBenchmark", dependencies: ["RattlegramCore"], path: "Sources/RattlegramBenchmark"),
        .testTarget(name: "RattlegramCoreTests", dependencies: ["RattlegramCore"], path: "Tests/RattlegramCoreTests"),
    ]
)
