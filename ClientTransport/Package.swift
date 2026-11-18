// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClientTransport",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MackerTransport", targets: ["MackerTransport"])],
    targets: [.target(name: "MackerTransport")]
)
