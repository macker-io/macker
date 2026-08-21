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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.10.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
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
            name: "LwIPCore",
            path: "Vendor/lwip",
            sources: [
                "src/api/err.c",
                "src/api/tcpip.c",
                "src/core/def.c",
                "src/core/inet_chksum.c",
                "src/core/init.c",
                "src/core/ip.c",
                "src/core/mem.c",
                "src/core/memp.c",
                "src/core/netif.c",
                "src/core/pbuf.c",
                "src/core/raw.c",
                "src/core/tcp.c",
                "src/core/tcp_in.c",
                "src/core/tcp_out.c",
                "src/core/timeouts.c",
                "src/core/udp.c",
                "src/core/ipv4/ip4.c",
                "src/core/ipv4/ip4_addr.c",
                "src/core/ipv4/ip4_frag.c",
            ],
            publicHeadersPath: "src/include",
            cSettings: [
                .headerSearchPath("../lwip-port"),
                .headerSearchPath("src/include"),
            ]
        ),
        .target(
            name: "LwIPPort",
            path: "Vendor/lwip-port",
            sources: [
                "sys_arch.c",
                "macker_lwip.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("../lwip/src/include"),
            ]
        ),
        .target(
            name: "ContainerEngine",
            dependencies: [
                // Link both C targets here. LwIPPort cannot depend on LwIPCore: SPM would
                // import lwIP's headers as a Clang module, and memp_std.h's X-macros fail.
                "HelperSupport",
                "LwIPCore",
                "LwIPPort",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
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
                "DockerAPIAdapter",
                "HelperSupport",
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
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
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
