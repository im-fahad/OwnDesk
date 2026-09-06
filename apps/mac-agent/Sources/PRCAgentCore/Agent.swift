import Foundation
import PRCIdentity
import PRCProtocol

/// Wires identity, trust, the signaling server, and the coordinator together. One per process.
public final class Agent: @unchecked Sendable {
    public let config: AgentConfig
    public let identity: any SigningIdentity
    public let trust: TrustStore
    public let coordinator: SessionCoordinator
    private let server: SignalingServer
    private let bridge: ServerBridge

    public var events: AsyncStream<AgentEvent> { coordinator.events }
    public var port: UInt16 { server.port }

    public init(config: AgentConfig, identity: (any SigningIdentity)? = nil, mediaFactory: MediaSessionFactory? = nil, input: (any InputSink)? = nil) throws {
        self.config = config
        if let identity {
            self.identity = identity
        } else if let file = config.identityFile {
            self.identity = try FileIdentityStore.loadOrCreate(at: file)
        } else {
            self.identity = try IdentityStore.loadOrCreate(service: config.keychainService)
        }
        trust = try TrustStore(directory: config.dataDirectory)

        let advertisement: SignalingServer.Advertisement? = config.advertiseBonjour
            ? .init(name: config.hostName, type: config.serviceType, txt: ["id": self.identity.deviceId, "name": config.hostName, "proto": String(Envelope.protocolVersion)])
            : nil
        server = SignalingServer(port: config.port, advertisement: advertisement)

        let media: MediaSessionFactory? = mediaFactory ?? (config.mediaEnabled ? { try LiveMediaSession(config: config) } : nil)
        let inputSink: (any InputSink)? = input ?? (config.inputEnabled ? InputInjector() : nil)
        coordinator = SessionCoordinator(.init(
            identity: self.identity, trust: trust, config: config, transport: server,
            mediaFactory: media, input: inputSink, power: PowerAssertion()
        ))
        bridge = ServerBridge(coordinator: coordinator)
        server.delegate = bridge
        let coordinator = self.coordinator
        server.onReady = { port in Task { await coordinator.setPort(port) } }
    }

    public func start() throws {
        try server.start()
    }

    public func stop() async {
        await coordinator.shutdown()
        server.stop()
    }

    /// The local kill switch (spec section 20). Off stops listening and advertising as well.
    public func setRemoteAccess(_ enabled: Bool) async throws {
        await coordinator.setRemoteAccess(enabled)
        if enabled { try server.start() } else { server.stop() }
    }
}

final class ServerBridge: SignalingServerDelegate, @unchecked Sendable {
    let coordinator: SessionCoordinator
    init(coordinator: SessionCoordinator) { self.coordinator = coordinator }

    func signaling(_ server: SignalingServer, didOpen id: ConnectionID, remote: String) {
        Log.signaling.info("connection from \(remote, privacy: .public)")
        Task { await coordinator.connectionOpened(id) }
    }
    func signaling(_ server: SignalingServer, didReceive text: String, from id: ConnectionID) {
        Task { await coordinator.handleText(text, from: id) }
    }
    func signaling(_ server: SignalingServer, didClose id: ConnectionID) {
        Task { await coordinator.connectionClosed(id) }
    }
}

/// Development-only identity persistence: a raw P-256 scalar in a 0600 file. Production uses IdentityStore.
public enum FileIdentityStore {
    public static func loadOrCreate(at url: URL) throws -> any SigningIdentity {
        if let data = try? Data(contentsOf: url) {
            return try SoftwareIdentity(rawRepresentation: data)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let identity = SoftwareIdentity()
        try identity.rawRepresentation.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return identity
    }
}
