import Foundation
import PRCProtocol

public struct ControllerConfig: Sendable {
    /// Name this controller shows to hosts when pairing.
    public var deviceName: String
    public var dataDirectory: URL
    public var keychainService: String
    /// Development only: software identity in a file instead of the Keychain.
    public var identityFile: URL?
    public var serviceType: String
    public var pingIntervalMs: Int
    public var missedPongsBeforeReconnect: Int
    public var reconnectWindowSeconds: Int
    /// How long to wait for the host's SESSION_CHALLENGE and SESSION_ACCEPT. A host that is not the
    /// one we paired with drops our messages silently (spec section 6 rule 3), so only a timeout
    /// distinguishes that from a slow network.
    public var authTimeoutSeconds: Int
    /// How long to wait for WebRTC to connect once the host has accepted.
    public var negotiateTimeoutSeconds: Int

    public init(
        deviceName: String,
        dataDirectory: URL,
        keychainService: String = "prc.controller.identity",
        identityFile: URL? = nil,
        serviceType: String = "_prc._tcp",
        pingIntervalMs: Int = Limits.pingIntervalMs,
        missedPongsBeforeReconnect: Int = Limits.missedPongsBeforeReconnect,
        reconnectWindowSeconds: Int = 60,
        authTimeoutSeconds: Int = 15,
        negotiateTimeoutSeconds: Int = 30
    ) {
        self.deviceName = deviceName
        self.dataDirectory = dataDirectory
        self.keychainService = keychainService
        self.identityFile = identityFile
        self.serviceType = serviceType
        self.pingIntervalMs = pingIntervalMs
        self.missedPongsBeforeReconnect = missedPongsBeforeReconnect
        self.reconnectWindowSeconds = reconnectWindowSeconds
        self.authTimeoutSeconds = authTimeoutSeconds
        self.negotiateTimeoutSeconds = negotiateTimeoutSeconds
    }

    public static func standard() -> ControllerConfig {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return ControllerConfig(deviceName: Host.current().localizedName ?? "Mac", dataDirectory: support.appendingPathComponent("PRC Controller", isDirectory: true))
    }
}

public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
