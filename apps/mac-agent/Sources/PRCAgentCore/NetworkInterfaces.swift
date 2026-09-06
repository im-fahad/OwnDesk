import Foundation

/// Addresses a controller on the same network can reach this Mac at. Used in the pairing QR.
public enum NetworkInterfaces {
    public static func lanAddresses(port: UInt16) -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            // Skip Apple's peer-to-peer and low-latency WLAN interfaces; they are not routable.
            if name.hasPrefix("awdl") || name.hasPrefix("llw") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let family = Int32(addr.pointee.sa_family)
            if family == AF_INET {
                guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let ip = String(cString: host)
                if ip.hasPrefix("169.254.") { continue }
                out.append("\(ip):\(port)")
            } else if family == AF_INET6 {
                guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let ip = String(cString: host)
                // Link-local addresses need a scope id that browsers cannot use.
                if ip.hasPrefix("fe80") { continue }
                out.append("[\(ip)]:\(port)")
            }
        }
        // IPv4 first: it is what most people will type or scan.
        return out.sorted { a, b in
            let a4 = !a.hasPrefix("["), b4 = !b.hasPrefix("[")
            return a4 != b4 ? a4 : a < b
        }
    }
}
