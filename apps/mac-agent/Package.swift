// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: the agent drives libwebrtc and ScreenCaptureKit through
// Objective-C delegate APIs that are not annotated for Swift 6 strict concurrency.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OwnDeskMacAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OwnDeskAgentCore", targets: ["OwnDeskAgentCore"]),
        .executable(name: "owndesk-agent", targets: ["owndesk-agent"]),
    ],
    dependencies: [
        .package(name: "OwnDeskSwift", path: "../../packages/swift"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "152.0.0"),
    ],
    targets: [
        .target(
            name: "OwnDeskAgentCore",
            dependencies: [
                .product(name: "OwnDeskIdentity", package: "OwnDeskSwift"),
                .product(name: "OwnDeskProtocol", package: "OwnDeskSwift"),
                .product(name: "OwnDeskPeers", package: "OwnDeskSwift"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: mode
        ),
        .executableTarget(name: "owndesk-agent", dependencies: ["OwnDeskAgentCore"], swiftSettings: mode),
        .testTarget(name: "OwnDeskAgentCoreTests", dependencies: ["OwnDeskAgentCore", .product(name: "WebRTC", package: "WebRTC")], swiftSettings: mode),
    ]
)
