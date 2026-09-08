// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRCSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRCIdentity", targets: ["PRCIdentity"]),
        .library(name: "PRCProtocol", targets: ["PRCProtocol"]),
        .library(name: "PRCLocalControl", targets: ["PRCLocalControl"]),
        .library(name: "PRCPeers", targets: ["PRCPeers"]),
    ],
    targets: [
        .target(name: "PRCIdentity"),
        .target(name: "PRCProtocol", dependencies: ["PRCIdentity"]),
        .target(name: "PRCLocalControl"),
        .target(name: "PRCPeers", dependencies: ["PRCIdentity", "PRCProtocol"]),
        .testTarget(name: "PRCProtocolTests", dependencies: ["PRCProtocol", "PRCIdentity"]),
        .testTarget(name: "PRCLocalControlTests", dependencies: ["PRCLocalControl", "PRCIdentity"]),
        .testTarget(name: "PRCPeersTests", dependencies: ["PRCPeers", "PRCIdentity", "PRCProtocol"]),
    ]
)
