// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRCSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRCIdentity", targets: ["PRCIdentity"]),
        .library(name: "PRCProtocol", targets: ["PRCProtocol"]),
        .library(name: "PRCLocalControl", targets: ["PRCLocalControl"]),
    ],
    targets: [
        .target(name: "PRCIdentity"),
        .target(name: "PRCProtocol", dependencies: ["PRCIdentity"]),
        .target(name: "PRCLocalControl"),
        .testTarget(name: "PRCProtocolTests", dependencies: ["PRCProtocol", "PRCIdentity"]),
        .testTarget(name: "PRCLocalControlTests", dependencies: ["PRCLocalControl", "PRCIdentity"]),
    ]
)
