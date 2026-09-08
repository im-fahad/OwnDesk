import Foundation
import Network

public enum Endpoints {
    /// Parses "192.168.1.20:47500", "[fd7a::1]:47500", or "mac-mini.local:47500" into a ws:// URL.
    public static func url(for address: String) -> URL? {
        var hostPart = address.trimmingCharacters(in: .whitespaces)
        var portPart = ""
        if hostPart.hasPrefix("[") {
            guard let close = hostPart.firstIndex(of: "]") else { return nil }
            let rest = hostPart[hostPart.index(after: close)...]
            hostPart = String(hostPart[hostPart.index(after: hostPart.startIndex)..<close])
            guard rest.hasPrefix(":") else { return nil }
            portPart = String(rest.dropFirst())
        } else {
            guard let colon = hostPart.lastIndex(of: ":") else { return nil }
            portPart = String(hostPart[hostPart.index(after: colon)...])
            hostPart = String(hostPart[..<colon])
        }
        guard !hostPart.isEmpty, let port = UInt16(portPart), port > 0 else { return nil }
        return url(host: hostPart, port: port)
    }

    public static func url(host: String, port: UInt16) -> URL? {
        let h = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        return URL(string: "ws://\(h):\(port)/")
    }

    /// Bonjour service endpoints have no address until connected. Resolve one by opening a TCP
    /// connection, reading the remote address, and closing it again.
    public static func resolve(_ endpoint: NWEndpoint, timeoutMs: Int = 5000) async -> URL? {
        switch endpoint {
        case .url(let u):
            return u
        case .hostPort(let host, let port):
            return url(host: "\(host)", port: port.rawValue)
        default:
            break
        }
        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            // Whatever address family the system picks is fine: Network.framework's WebSocket client
            // accepts scoped link-local IPv6 URLs, and forcing IPv4 makes mDNS resolution unreliable.
            let connection = NWConnection(to: endpoint, using: .tcp)
            let done = Locked(false)
            let finish: @Sendable (URL?) -> Void = { url in
                guard !done.get() else { return }
                done.set(true)
                connection.cancel()
                c.resume(returning: url)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        finish(url(host: "\(host)", port: port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                case .waiting:
                    // mDNS address lookup can pass through waiting; the timeout below decides.
                    break
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "prc.resolve"))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { finish(nil) }
        }
    }

    /// Opens a TCP connection to every candidate at once and returns the first that answers, so a
    /// controller carrying both a home LAN address and an overlay address connects from anywhere
    /// without the user picking one. Losers are cancelled as soon as a winner appears.
    public static func firstReachable(_ urls: [URL], timeoutMs: Int = 4000) async -> URL? {
        let candidates = urls.filter { $0.host != nil }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return await isReachable(candidates[0], timeoutMs: timeoutMs) ? candidates[0] : nil }

        return await withTaskGroup(of: URL?.self) { group in
            for url in candidates {
                group.addTask { await isReachable(url, timeoutMs: timeoutMs) ? url : nil }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// A plain TCP connect. It proves the port is open, not that the right host is behind it;
    /// the signed handshake decides that.
    public static func isReachable(_ url: URL, timeoutMs: Int = 4000) async -> Bool {
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 0)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "prc.probe")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let done = Locked(false)
                let finish: @Sendable (Bool) -> Void = { ok in
                    guard !done.get() else { return }
                    done.set(true)
                    connection.cancel()
                    c.resume(returning: ok)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .cancelled: finish(false)
                    case .waiting: finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        case .service(let name, _, _, _): return "\(name) (Bonjour)"
        case .url(let u): return u.absoluteString
        default: return "\(endpoint)"
        }
    }
}
