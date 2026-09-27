// swift-tools-version: 6.0
import PackageDescription

// The terminal: an SSH client to a Mac's own SSH server (Remote Login), for the iPhone app now and
// the Mac app later. OwnDesk's protocol never runs a command; here OpenSSH does, behind its own
// authentication, and this package only speaks SSH to it. No UI: the apps draw the terminal.

// Swift 5 language mode, as in the other packages that hold network handlers: NIO's channel handlers
// are confined to their event loop in ways the Swift 6 checker cannot see.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OwnDeskTerminal",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OwnDeskTerminal", targets: ["OwnDeskTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(
            name: "OwnDeskTerminal",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: mode
        ),
        .testTarget(
            name: "OwnDeskTerminalTests",
            dependencies: ["OwnDeskTerminal", .product(name: "NIOSSH", package: "swift-nio-ssh")],
            swiftSettings: mode
        ),
    ]
)
