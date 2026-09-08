// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode, as with both halves: libwebrtc and ScreenCaptureKit are driven through
// Objective-C delegates that are not annotated for Swift 6 strict concurrency.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "PRC",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "prc", targets: ["prc"]),
    ],
    dependencies: [
        .package(name: "PRCSwift", path: "../../packages/swift"),
        .package(name: "PRCMacAgent", path: "../mac-agent"),
        .package(name: "PRCMacController", path: "../mac-controller"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "152.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "prc",
            dependencies: [
                .product(name: "PRCIdentity", package: "PRCSwift"),
                .product(name: "PRCProtocol", package: "PRCSwift"),
                .product(name: "PRCPeers", package: "PRCSwift"),
                .product(name: "PRCLocalControl", package: "PRCSwift"),
                .product(name: "PRCAgentCore", package: "PRCMacAgent"),
                .product(name: "PRCControllerCore", package: "PRCMacController"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            swiftSettings: mode
        ),
    ]
)
