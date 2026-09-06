import Foundation
import Network

public typealias ConnectionID = UUID

/// Anything that can deliver a text frame to a signaling connection. The coordinator talks to this,
/// so tests can substitute an in-memory transport.
public protocol SignalingTransport: AnyObject, Sendable {
    func send(_ text: String, to id: ConnectionID)
    func close(_ id: ConnectionID)
}

public protocol SignalingServerDelegate: AnyObject, Sendable {
    func signaling(_ server: SignalingServer, didOpen id: ConnectionID, remote: String)
    func signaling(_ server: SignalingServer, didReceive text: String, from id: ConnectionID)
    func signaling(_ server: SignalingServer, didClose id: ConnectionID)
}

/// The agent's embedded signaling endpoint: a WebSocket server over TCP, optionally advertised via Bonjour.
/// Transport security is deliberately absent on the LAN: every message is a signed envelope and
/// contains no secrets (spec section 17).
public final class SignalingServer: SignalingTransport, @unchecked Sendable {
    public struct Advertisement: Sendable {
        public var name: String
        public var type: String
        public var txt: [String: String]
        public init(name: String, type: String, txt: [String: String]) {
            self.name = name; self.type = type; self.txt = txt
        }
    }

    public static let maxMessageBytes = 1 << 17

    private let queue = DispatchQueue(label: "prc.signaling")
    private let requestedPort: UInt16
    private let advertisement: Advertisement?
    private var listener: NWListener?
    private var connections: [ConnectionID: NWConnection] = [:]
    private let lock = NSLock()

    public weak var delegate: SignalingServerDelegate?
    /// Actual port once listening. Meaningful after `onReady` fires.
    public private(set) var port: UInt16 = 0
    public var onReady: (@Sendable (UInt16) -> Void)?
    public var onFailure: (@Sendable (Error) -> Void)?

    public init(port: UInt16, advertisement: Advertisement?) {
        requestedPort = port
        self.advertisement = advertisement
    }

    public func start() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = SignalingServer.maxMessageBytes
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true

        let port: NWEndpoint.Port = requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!
        let listener = try NWListener(using: params, on: port)
        if let adv = advertisement {
            listener.service = NWListener.Service(name: adv.name, type: adv.type, txtRecord: NWTXTRecord(adv.txt))
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                Log.signaling.info("listening on port \(self.port, privacy: .public)")
                self.onReady?(self.port)
            case .failed(let error):
                Log.signaling.error("listener failed: \(error.localizedDescription, privacy: .public)")
                self.onFailure?(error)
            case .cancelled:
                Log.signaling.info("listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let all = connections
        connections.removeAll()
        lock.unlock()
        all.values.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ConnectionID()
        lock.lock(); connections[id] = connection; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.delegate?.signaling(self, didOpen: id, remote: "\(connection.endpoint)")
                self.receive(id, connection)
            case .failed, .cancelled:
                self.remove(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ id: ConnectionID, _ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if error != nil { self.remove(id); return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text, .binary:
                    if let data, let text = String(data: data, encoding: .utf8) {
                        self.delegate?.signaling(self, didReceive: text, from: id)
                    }
                case .close:
                    self.remove(id)
                    return
                default:
                    break
                }
            } else if data == nil, isComplete {
                self.remove(id)
                return
            }
            self.receive(id, connection)
        }
    }

    private func remove(_ id: ConnectionID) {
        lock.lock()
        let connection = connections.removeValue(forKey: id)
        lock.unlock()
        guard let connection else { return }
        connection.cancel()
        delegate?.signaling(self, didClose: id)
    }

    // MARK: SignalingTransport

    public func send(_ text: String, to id: ConnectionID) {
        lock.lock(); let connection = connections[id]; lock.unlock()
        guard let connection else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error { Log.signaling.error("send failed: \(error.localizedDescription, privacy: .public)") }
        })
    }

    public func close(_ id: ConnectionID) {
        remove(id)
    }
}
