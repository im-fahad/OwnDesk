// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: the agent drives libwebrtc and ScreenCaptureKit through
// Objective-C delegate APIs that are not annotated for Swift 6 strict concurrency.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "PRCMacAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRCAgentCore", targets: ["PRCAgentCore"]),
        .executable(name: "prc-agent", targets: ["prc-agent"]),
        .executable(name: "prc-agent-app", targets: ["prc-agent-app"]),
    ],
    dependencies: [
        .package(name: "PRCSwift", path: "../../packages/swift"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "152.0.0"),
    ],
    targets: [
        .target(
            name: "PRCAgentCore",
            dependencies: [
                .product(name: "PRCIdentity", package: "PRCSwift"),
                .product(name: "PRCProtocol", package: "PRCSwift"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: mode
        ),
        .executableTarget(name: "prc-agent", dependencies: ["PRCAgentCore"], swiftSettings: mode),
        .executableTarget(name: "prc-agent-app", dependencies: ["PRCAgentCore"], swiftSettings: mode),
        .testTarget(name: "PRCAgentCoreTests", dependencies: ["PRCAgentCore", .product(name: "WebRTC", package: "WebRTC")], swiftSettings: mode),
    ]
)
