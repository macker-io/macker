    // swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macker-daemon",
    platforms: [
        // apple/containerization requires macOS 15+; .v14 cannot resolve the local path dependency.
        .macOS(.v15),
    ],
    products: [
        .executable(name: "mackerd", targets: ["Daemon"]),
        .executable(name: "macker", targets: ["Cli"]),
        .executable(name: "macker-helper", targets: ["Helper"]),
        .library(name: "ContainerEngine", targets: ["ContainerEngine"]),
        .library(name: "DockerAPIAdapter", targets: ["DockerAPIAdapter"]),
        .library(name: "HelperSupport", targets: ["HelperSupport"]),
    ],
    dependencies: [
        .package(path: "./Vendor/containerization"),
        .package(path: "./ClientTransport"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.45.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
        .package(url: "https://github.com/PrizmX/SwiftTCP.git", revision: "006725d09483b87286b067c7b1b19945b2c7998c"),
    ],
    targets: [
        .executableTarget(
            name: "Daemon",
            dependencies: [
                "ContainerEngine",
                "DockerAPIAdapter",
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["Daemon.entitlements"]
        ),
        .target(
            name: "CliCore",
            dependencies: [
                "ContainerEngine",
                "HelperSupport",
                .product(name: "MackerTransport", package: "ClientTransport"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/Cli"
        ),
        .executableTarget(
            name: "Cli",
            dependencies: ["CliCore"],
            path: "Sources/CliMain"
        ),
        .target(name: "HelperSupport"),
        .executableTarget(
            name: "Helper",
            dependencies: ["HelperSupport"],
            path: "Sources/Helper"
        ),
        .target(
            name: "ContainerEngine",
            dependencies: [
                "HelperSupport",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftTCP", package: "SwiftTCP"),
            ],
            resources: [
                .copy("RuntimePin.json"),
            ]
        ),
        .testTarget(
            name: "ContainerEngineTests",
            dependencies: [
                "ContainerEngine",
                "DockerAPIAdapter",
                "HelperSupport",
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "CliTests",
            dependencies: [
                "CliCore",
                "ContainerEngine",
                "DockerAPIAdapter",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "DockerAPIAdapter",
            dependencies: [
                "ContainerEngine",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
