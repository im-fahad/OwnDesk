// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode for the same reason as the agent: libwebrtc's Objective-C delegates.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OwnDeskMacController",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OwnDeskControllerCore", targets: ["OwnDeskControllerCore"]),
        .executable(name: "owndesk-controller-cli", targets: ["owndesk-controller-cli"]),
    ],
    dependencies: [
        .package(name: "OwnDeskSwift", path: "../../packages/swift"),
        .package(name: "OwnDeskMacAgent", path: "../mac-agent"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "152.0.0"),
    ],
    targets: [
        .target(
            name: "OwnDeskControllerCore",
            dependencies: [
                .product(name: "OwnDeskIdentity", package: "OwnDeskSwift"),
                .product(name: "OwnDeskProtocol", package: "OwnDeskSwift"),
                .product(name: "OwnDeskPeers", package: "OwnDeskSwift"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: mode
        ),
        .executableTarget(name: "owndesk-controller-cli", dependencies: ["OwnDeskControllerCore", .product(name: "OwnDeskLocalControl", package: "OwnDeskSwift"), .product(name: "WebRTC", package: "WebRTC")], swiftSettings: mode),
        .testTarget(
            name: "OwnDeskControllerCoreTests",
            dependencies: ["OwnDeskControllerCore", .product(name: "OwnDeskAgentCore", package: "OwnDeskMacAgent"), .product(name: "WebRTC", package: "WebRTC")],
            swiftSettings: mode
        ),
    ]
)
