// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PiWaypointPackage",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PiRPCTestHarness",
            targets: ["PiRPCTestHarness"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PiRPCTestHarness"
        ),
        .testTarget(
            name: "PiRPCTestHarnessTests",
            dependencies: ["PiRPCTestHarness"],
            resources: [
                .copy("Fixtures/unknown-command.replay.ndjson"),
                .copy("Fixtures/unknown-command.stdin.jsonl"),
                .copy("Fixtures/unknown-command.stdout.jsonl"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
