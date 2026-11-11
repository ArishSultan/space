// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Space",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SpaceCore", targets: ["SpaceCore"]),
        .executable(name: "spaced", targets: ["spaced"]),
        .executable(name: "Space", targets: ["SpaceApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "SpaceCore",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Recipes")]
        ),
        // Tailscale's official embeddable client, built by scripts/build-tailscalekit.sh.
        .binaryTarget(name: "TailscaleKit", path: "Vendor/TailscaleKit.xcframework"),
        .target(name: "SpaceNet", dependencies: ["SpaceCore", "TailscaleKit"]),
        // MCP server (tools for agents); every tool calls the spaced HTTP API.
        .target(name: "SpaceMCP", dependencies: ["SpaceCore", .product(name: "MCP", package: "swift-sdk")]),
        .target(
            name: "SpaceServer",
            dependencies: [
                "SpaceCore", "SpaceNet", "SpaceMCP",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "spaced",
            dependencies: [
                "SpaceCore", "SpaceNet", "SpaceServer", "SpaceMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Menu-bar app: a thin SwiftUI client of the spaced API (no third-party UI code).
        .executableTarget(name: "SpaceApp", dependencies: [
            "SpaceCore",
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
        ]),
        .testTarget(name: "SpaceCoreTests", dependencies: ["SpaceCore", "SpaceNet"]),
    ]
)
