import Foundation
import Network

/// A tiny same-user control channel so a CLI can drive the running GUI app (pair, approve,
/// connect, status) for scripts and tests. The server listens on 127.0.0.1 on a random port and
/// writes `{port, token}` to a 0600 file in the app's private data directory; every request must
/// carry that token. Every command maps to a button the app already has; nothing here executes
/// commands or code, and nothing is reachable from the network.

public struct ControlRequest: Codable, Sendable {
    public var id: String
    public var token: String
    public var command: String
    public var args: [String]

    public init(command: String, args: [String] = [], token: String = "") {
        id = UUID().uuidString
        self.token = token
        self.command = command
        self.args = args
    }
}

public struct ControlResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var message: String
    public var data: [String: String]

    public init(id: String = "", ok: Bool, message: String = "", data: [String: String] = [:]) {
        self.id = id; self.ok = ok; self.message = message; self.data = data
    }

    public static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, message: message) }
}

public struct ControlEndpoint: Codable, Sendable {
    public var port: UInt16
    public var token: String
    public init(port: UInt16, token: String) { self.port = port; self.token = token }
}

public enum LocalControlError: Error, Sendable {
    case notRunning
    case cannotConnect(String)
    case timeout
    case badResponse
}

public final class LocalControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let controlFile: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "prc.localcontrol")
    private var listener: NWListener?
    private let token: String

    public init(controlFile: URL, handler: @escaping Handler) {
        self.controlFile = controlFile
        self.handler = handler
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = listener.port?.rawValue else { return }
            self.writeControlFile(port: port)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: controlFile)
    }

    private func writeControlFile(port: UInt16) {
        do {
            try FileManager.default.createDirectory(at: controlFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(ControlEndpoint(port: port, token: token)).write(to: controlFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: controlFile.path)
        } catch {
            listener?.cancel()
        }
    }

    private func serve(_ connection: NWConnection) {
        let session = ServerSession(connection: connection, token: token, handler: handler)
        session.start(queue: queue)
    }
}

private final class ServerSession: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let handler: LocalControlServer.Handler
    private var buffer = Data()

    init(connection: NWConnection, token: String, handler: @escaping LocalControlServer.Handler) {
        self.connection = connection
        self.token = token
        self.handler = handler
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(line)
            }
            if isComplete || error != nil { connection.cancel(); return }
            receive()
        }
    }

    private func handle(_ line: Data) {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            send(.failure("bad request"))
            return
        }
        guard constantTimeEqual(request.token, token) else {
            send(ControlResponse(id: request.id, ok: false, message: "bad token"))
            return
        }
        let handler = self.handler
        Task { [self] in
            var response = await handler(request)
            response.id = request.id
            send(response)
        }
    }

    private func send(_ response: ControlResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

public enum LocalControlClient {
    public static func readEndpoint(_ controlFile: URL) throws -> ControlEndpoint {
        guard let data = try? Data(contentsOf: controlFile), let endpoint = try? JSONDecoder().decode(ControlEndpoint.self, from: data) else {
            throw LocalControlError.notRunning
        }
        return endpoint
    }

    public static func send(_ request: ControlRequest, controlFile: URL, timeoutMs: Int = 130_000) async throws -> ControlResponse {
        let endpoint = try readEndpoint(controlFile)
        var request = request
        request.token = endpoint.token
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw LocalControlError.notRunning }
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<ControlResponse, Error>) in
            ClientSession(connection: connection, request: request, continuation: c).start(timeoutMs: timeoutMs)
        }
    }
}

private final class ClientSession: @unchecked Sendable {
    private let connection: NWConnection
    private let request: ControlRequest
    private let queue = DispatchQueue(label: "prc.localcontrol.client")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ControlResponse, Error>?
    private var buffer = Data()

    init(connection: NWConnection, request: ControlRequest, continuation: CheckedContinuation<ControlResponse, Error>) {
        self.connection = connection
        self.request = request
        self.continuation = continuation
    }

    func start(timeoutMs: Int) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard var data = try? JSONEncoder().encode(request) else { finish(.failure(LocalControlError.badResponse)); return }
                data.append(0x0A)
                connection.send(content: data, completion: .contentProcessed { _ in })
                receive()
            case .failed(let error), .waiting(let error):
                finish(.failure(LocalControlError.cannotConnect(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [self] in finish(.failure(LocalControlError.timeout)) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                if let response = try? JSONDecoder().decode(ControlResponse.self, from: line) {
                    finish(.success(response))
                } else {
                    finish(.failure(LocalControlError.badResponse))
                }
                return
            }
            if isComplete || error != nil { finish(.failure(LocalControlError.badResponse)); return }
            receive()
        }
    }

    private func finish(_ result: Result<ControlResponse, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        connection.cancel()
        c.resume(with: result)
    }
}

private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}
