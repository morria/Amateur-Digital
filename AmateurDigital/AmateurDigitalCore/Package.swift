// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AmateurDigitalCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AmateurDigitalCore",
            targets: ["AmateurDigitalCore"]
        ),
        .executable(
            name: "GenerateTestAudio",
            targets: ["GenerateTestAudio"]
        ),
        .executable(
            name: "DecodeWAV",
            targets: ["DecodeWAV"]
        ),
        .executable(
            name: "PSKBenchmark",
            targets: ["PSKBenchmark"]
        ),
        .executable(
            name: "CWBenchmark",
            targets: ["CWBenchmark"]
        ),
        .executable(
            name: "JS8Benchmark",
            targets: ["JS8Benchmark"]
        ),
        .executable(
            name: "RTTYBenchmark",
            targets: ["RTTYBenchmark"]
        ),
    ],
    targets: [
        .target(
            name: "AmateurDigitalCore",
            dependencies: [],
            path: "Sources/AmateurDigitalCore"
        ),
        .executableTarget(
            name: "GenerateTestAudio",
            dependencies: ["AmateurDigitalCore"],
            path: "Sources/GenerateTestAudio"
        ),
        .executableTarget(
            name: "DecodeWAV",
            dependencies: ["AmateurDigitalCore"],
            path: "Sources/DecodeWAV"
        ),
        .executableTarget(
            name: "PSKBenchmark",
            dependencies: ["AmateurDigitalCore"],
            path: "Sources/PSKBenchmark"
        ),
        .executableTarget(
            name: "CWBenchmark",
            dependencies: ["AmateurDigitalCore"],
            path: "Sources/CWBenchmark"
        ),
        .executableTarget(
            name: "JS8Benchmark",
            dependencies: ["AmateurDigitalCore"],
            path: "Sources/JS8Benchmark"
        ),
        .executableTarget(
            name: "RTTYBenchmark",
            dependencies: ["AmateurDigitalCore"],
            path: "Sources/RTTYBenchmark"
        ),
        .testTarget(
            name: "AmateurDigitalCoreTests",
            dependencies: ["AmateurDigitalCore"],
            path: "Tests/AmateurDigitalCoreTests"
        ),
    ]
)
