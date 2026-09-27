// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode, as with both halves: libwebrtc and ScreenCaptureKit are driven through
// Objective-C delegates that are not annotated for Swift 6 strict concurrency.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OwnDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "owndesk", targets: ["owndesk"]),
    ],
    dependencies: [
        .package(name: "OwnDeskSwift", path: "../../packages/swift"),
        .package(name: "OwnDeskMacAgent", path: "../mac-agent"),
        .package(name: "OwnDeskMacController", path: "../mac-controller"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "152.0.0"),
        .package(name: "OwnDeskTerminal", path: "../../packages/terminal"),
        // Pinned below 1.12: later releases need a trusted build plugin and a Metal toolchain download.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", "1.11.2"..<"1.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "owndesk",
            dependencies: [
                .product(name: "OwnDeskIdentity", package: "OwnDeskSwift"),
                .product(name: "OwnDeskProtocol", package: "OwnDeskSwift"),
                .product(name: "OwnDeskPeers", package: "OwnDeskSwift"),
                .product(name: "OwnDeskLocalControl", package: "OwnDeskSwift"),
                .product(name: "OwnDeskAgentCore", package: "OwnDeskMacAgent"),
                .product(name: "OwnDeskControllerCore", package: "OwnDeskMacController"),
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "OwnDeskTerminal", package: "OwnDeskTerminal"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: mode
        ),
    ]
)
