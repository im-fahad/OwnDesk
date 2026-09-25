// swift-tools-version: 6.0
import PackageDescription

// What the iPhone app's fingers and keys mean, kept free of UIKit so it runs under `swift test` on a
// Mac with no simulator: gestures, where a finger lands on the Mac's screen, and which key a keyboard
// pressed. The app is a thin layer over this.
let package = Package(
    name: "OwnDeskTouch",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OwnDeskTouch", targets: ["OwnDeskTouch"]),
    ],
    dependencies: [
        .package(name: "OwnDeskSwift", path: "../../../packages/swift"),
    ],
    targets: [
        .target(name: "OwnDeskTouch", dependencies: [.product(name: "OwnDeskProtocol", package: "OwnDeskSwift")]),
        .testTarget(name: "OwnDeskTouchTests", dependencies: ["OwnDeskTouch", .product(name: "OwnDeskProtocol", package: "OwnDeskSwift")]),
    ]
)
