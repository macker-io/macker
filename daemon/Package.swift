// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macker-daemon",
    platforms: [
        // apple/containerization requires macOS 15+; .v14 cannot resolve the local path dependency.
        .macOS(.v15),
    ],
    products: [
        .executable(name: "App", targets: ["App"]),
        .executable(name: "macker", targets: ["cli"]),
        .library(name: "ContainerEngine", targets: ["ContainerEngine"]),
        .library(name: "DockerAPIAdapter", targets: ["DockerAPIAdapter"]),
    ],
    dependencies: [
        .package(path: "./Vendor/containerization"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                "ContainerEngine",
                "DockerAPIAdapter",
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["App.entitlements"]
        ),
        .executableTarget(
            name: "cli",
            dependencies: [
                "ContainerEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Cmd"
        ),
        .target(
            name: "ContainerEngine",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [
                .copy("RuntimePin.json"),
            ]
        ),
        .testTarget(
            name: "ContainerEngineTests",
            dependencies: [
                "ContainerEngine",
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(
            name: "DockerAPIAdapter",
            dependencies: [
                "ContainerEngine",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
