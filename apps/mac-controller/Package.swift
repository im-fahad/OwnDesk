// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode for the same reason as the agent: libwebrtc's Objective-C delegates.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "PRCMacController",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRCControllerCore", targets: ["PRCControllerCore"]),
        .executable(name: "prc-controller", targets: ["prc-controller"]),
        .executable(name: "prc-controller-cli", targets: ["prc-controller-cli"]),
    ],
    dependencies: [
        .package(name: "PRCSwift", path: "../../packages/swift"),
        .package(name: "PRCMacAgent", path: "../mac-agent"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "152.0.0"),
    ],
    targets: [
        .target(
            name: "PRCControllerCore",
            dependencies: [
                .product(name: "PRCIdentity", package: "PRCSwift"),
                .product(name: "PRCProtocol", package: "PRCSwift"),
                .product(name: "PRCPeers", package: "PRCSwift"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: mode
        ),
        .executableTarget(name: "prc-controller", dependencies: ["PRCControllerCore", .product(name: "PRCLocalControl", package: "PRCSwift")], swiftSettings: mode),
        .executableTarget(name: "prc-controller-cli", dependencies: ["PRCControllerCore", .product(name: "PRCLocalControl", package: "PRCSwift"), .product(name: "WebRTC", package: "WebRTC")], swiftSettings: mode),
        .testTarget(
            name: "PRCControllerCoreTests",
            dependencies: ["PRCControllerCore", .product(name: "PRCAgentCore", package: "PRCMacAgent"), .product(name: "WebRTC", package: "WebRTC")],
            swiftSettings: mode
        ),
    ]
)
