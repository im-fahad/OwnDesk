// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRCSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRCIdentity", targets: ["PRCIdentity"]),
        .library(name: "PRCProtocol", targets: ["PRCProtocol"]),
    ],
    targets: [
        .target(name: "PRCIdentity"),
        .target(name: "PRCProtocol", dependencies: ["PRCIdentity"]),
        .testTarget(name: "PRCProtocolTests", dependencies: ["PRCProtocol", "PRCIdentity"]),
    ]
)
