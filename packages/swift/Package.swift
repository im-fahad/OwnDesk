// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OwnDeskSwift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OwnDeskIdentity", targets: ["OwnDeskIdentity"]),
        .library(name: "OwnDeskProtocol", targets: ["OwnDeskProtocol"]),
        .library(name: "OwnDeskLocalControl", targets: ["OwnDeskLocalControl"]),
        .library(name: "OwnDeskPeers", targets: ["OwnDeskPeers"]),
    ],
    targets: [
        .target(name: "OwnDeskIdentity"),
        .target(name: "OwnDeskProtocol", dependencies: ["OwnDeskIdentity"]),
        .target(name: "OwnDeskLocalControl"),
        .target(name: "OwnDeskPeers", dependencies: ["OwnDeskIdentity", "OwnDeskProtocol"]),
        .testTarget(name: "OwnDeskProtocolTests", dependencies: ["OwnDeskProtocol", "OwnDeskIdentity"]),
        .testTarget(name: "OwnDeskLocalControlTests", dependencies: ["OwnDeskLocalControl", "OwnDeskIdentity"]),
        .testTarget(name: "OwnDeskPeersTests", dependencies: ["OwnDeskPeers", "OwnDeskIdentity", "OwnDeskProtocol"]),
    ]
)
