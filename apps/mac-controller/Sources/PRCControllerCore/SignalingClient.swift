import Foundation
import Network

/// WebSocket client over Network.framework. Takes a ws:// URL; Bonjour services are resolved to an
/// address first by `Endpoints.resolve`.
public final class SignalingClient: @unchecked Sendable {
    public enum Event: Sendable {
        case opened
        case message(String)
        case closed(String?)
    }

    private let queue = DispatchQueue(label: "prc.signaling.client")
    private var connection: NWConnection?
    private let url: URL
    private var closedReported = false
    public var onEvent: (@Sendable (Event) -> Void)?

    public init(url: URL) {
        self.url = url
    }

    public func connect() {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 17
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let connection = NWConnection(to: .url(url), using: params)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent?(.opened)
                self.receive(connection)
            case .failed(let error):
                self.reportClosed(error.localizedDescription)
            case .cancelled:
                self.reportClosed(nil)
            case .waiting(let error):
                // A refused or unreachable host parks the connection in waiting. Fail fast; callers retry with backoff.
                self.reportClosed(error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let error { self.reportClosed(error.localizedDescription); return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text, .binary:
                    if let data, let text = String(data: data, encoding: .utf8) { self.onEvent?(.message(text)) }
                case .close:
                    self.reportClosed("closed by host")
                    return
                default:
                    break
                }
            } else if data == nil, isComplete {
                self.reportClosed(nil)
                return
            }
            self.receive(connection)
        }
    }

    public func send(_ text: String) {
        guard let connection else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    public func close() {
        connection?.cancel()
        connection = nil
    }

    private func reportClosed(_ reason: String?) {
        guard !closedReported else { return }
        closedReported = true
        connection?.cancel()
        connection = nil
        onEvent?(.closed(reason))
    }
}
