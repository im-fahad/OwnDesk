import Foundation
import PRCProtocol

public struct AgentConfig: Sendable {
    /// Shown to controllers and advertised over Bonjour. Not a secret.
    public var hostName: String
    /// 0 picks an ephemeral port (tests). The spec default is 47500.
    public var port: UInt16
    public var serviceType: String
    public var advertiseBonjour: Bool
    public var dataDirectory: URL
    public var keychainService: String
    public var rendezvousURL: String?
    public var idleTimeout: TimeInterval
    public var maxBitrateBps: Int
    public var maxFramerate: Int
    public var maxLongEdge: Int
    /// When false the agent runs signaling and sessions only, without screen capture or WebRTC.
    public var mediaEnabled: Bool
    /// When false, input messages are validated and counted but never injected.
    public var inputEnabled: Bool
    /// Development only. When set, the identity is a software key in this file instead of the Keychain,
    /// so every rebuilt ad-hoc-signed binary can read it without a Keychain prompt.
    public var identityFile: URL?
    /// TEST ONLY. Stream a generated pattern instead of the screen, so no Screen Recording permission is needed.
    public var syntheticScreen: Bool

    public static let defaultPort: UInt16 = 47500
    public static let serviceType = "_prc._tcp"

    public init(
        hostName: String,
        port: UInt16 = AgentConfig.defaultPort,
        serviceType: String = AgentConfig.serviceType,
        advertiseBonjour: Bool = true,
        dataDirectory: URL,
        keychainService: String = "prc.agent.identity",
        rendezvousURL: String? = nil,
        idleTimeout: TimeInterval = TimeInterval(Limits.idleTimeoutMinutes * 60),
        maxBitrateBps: Int = 20_000_000,
        maxFramerate: Int = 60,
        maxLongEdge: Int = 1920,
        mediaEnabled: Bool = true,
        inputEnabled: Bool = true,
        identityFile: URL? = nil,
        syntheticScreen: Bool = false
    ) {
        self.hostName = hostName
        self.port = port
        self.serviceType = serviceType
        self.advertiseBonjour = advertiseBonjour
        self.dataDirectory = dataDirectory
        self.keychainService = keychainService
        self.rendezvousURL = rendezvousURL
        self.idleTimeout = idleTimeout
        self.maxBitrateBps = maxBitrateBps
        self.maxFramerate = maxFramerate
        self.maxLongEdge = maxLongEdge
        self.mediaEnabled = mediaEnabled
        self.inputEnabled = inputEnabled
        self.identityFile = identityFile
        self.syntheticScreen = syntheticScreen
    }

    public static func standard() -> AgentConfig {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return AgentConfig(hostName: Host.current().localizedName ?? "Mac", dataDirectory: support.appendingPathComponent("PRC", isDirectory: true))
    }
}

public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
