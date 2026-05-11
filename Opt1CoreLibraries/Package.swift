// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Opt1CoreLibraries",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Opt1Core", targets: ["Opt1Core"]),
        .library(name: "Opt1Solvers", targets: ["Opt1Solvers"]),
        .library(name: "Opt1Detection", targets: ["Opt1Detection"]),
        .library(name: "Opt1CelticKnot", targets: ["Opt1CelticKnot"]),
        .library(name: "Opt1Matching", targets: ["Opt1Matching"]),
    ],
    targets: [
        .target(name: "Opt1Core"),
        .target(name: "Opt1Solvers", dependencies: ["Opt1Core"]),
        .target(name: "Opt1Detection", dependencies: ["Opt1Core", "Opt1Solvers"]),
        .target(name: "Opt1CelticKnot", dependencies: ["Opt1Core", "Opt1Detection"]),
        .target(
            name: "Opt1Matching",
            resources: [.process("Resources/clues.json")]
        ),
        .testTarget(name: "Opt1SolversTests", dependencies: ["Opt1Solvers"]),
        .testTarget(name: "Opt1DetectionTests", dependencies: ["Opt1Detection"]),
        .testTarget(
            name: "Opt1CelticKnotTests",
            dependencies: ["Opt1CelticKnot"],
            exclude: ["Fixtures"]
        ),
        .testTarget(name: "Opt1MatchingTests", dependencies: ["Opt1Matching"]),
    ]
)
