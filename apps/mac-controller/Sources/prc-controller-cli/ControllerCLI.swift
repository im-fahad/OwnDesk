import Foundation
import Network
import PRCControllerCore
import PRCIdentity
import PRCLocalControl
import PRCProtocol
import WebRTC

final class Box<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

/// Headless controller for scripted and remote testing (for example over SSH from another Mac).
/// Same core as the app, no window. Uses a file identity by default because an SSH session has no
/// Keychain UI.
@main
enum ControllerCLI {
    static let usage = """
    prc-controller-cli <command> [options]

      discover [--seconds N]                       list hosts advertised on this network
      pair <qr-json | --qr-file path> [--address a] pair with a host; approve on the host when it shows this fingerprint
      connect <host id prefix | name> [--address a] [--seconds N] [--probe-input]
                                                   authenticate, receive video, measure RTT, then disconnect
      hosts                                        list paired hosts
      app <command> [args]                         drive the running PRC Controller app:
                                                   status | hosts | pair <payload|@file> [address] |
                                                   connect <host> [address] | disconnect | forget <host> | quit

    Options: --data-dir <path>  --name <text>  --keychain (use the Keychain instead of <data-dir>/identity.key)
    """

    final class Counter: NSObject, RTCVideoRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var frames = 0
        private(set) var size = CGSize.zero
        func setSize(_ size: CGSize) { lock.lock(); self.size = size; lock.unlock() }
        func renderFrame(_ frame: RTCVideoFrame?) { lock.lock(); frames += 1; lock.unlock() }
        var snapshot: (Int, CGSize) { lock.lock(); defer { lock.unlock() }; return (frames, size) }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        var states: [SessionClient.State] = []
        var rtts: [Double] = []
        var display: DisplayInfo?
        func record(_ e: SessionClient.Event) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .state(let s): states.append(s); print("  state: \(describe(s))")
            case .rtt(let r): rtts.append(r)
            case .display(let d): display = d
            case .remoteVideo: print("  video track received")
            case .log(let t): print("  log: \(t)")
            }
        }
        func hasState(_ f: (SessionClient.State) -> Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return states.contains(where: f) }
        var lastRTT: Double? { lock.lock(); defer { lock.unlock() }; return rtts.last }
        var rttCount: Int { lock.lock(); defer { lock.unlock() }; return rtts.count }
    }

    static func describe(_ s: SessionClient.State) -> String {
        switch s {
        case .idle: "idle"
        case .connecting: "connecting"
        case .authenticating: "authenticating"
        case .negotiating: "negotiating"
        case .connected(let p): "connected (\(p))"
        case .reconnecting(let w): "reconnecting: \(w)"
        case .ended(let r): "ended: \(r)"
        }
    }

    static var failures = 0
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        print("\(ok ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failures += 1 }
    }

    static func waitUntil(timeoutMs: Int, _ label: String, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("  timeout waiting for \(label)")
        return false
    }

    static func main() async throws {
        setlinebuf(stdout)
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { print(usage); exit(2) }
        let command = args.removeFirst()
        if command == "app" {
            await controlApp(args)
            return
        }

        var config = ControllerConfig.standard()
        var positional: [String] = []
        var address: String? = nil
        var seconds = 10
        var probeInput = false
        var qrFile: String? = nil
        var useKeychain = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--data-dir": if !args.isEmpty { config.dataDirectory = URL(fileURLWithPath: args.removeFirst(), isDirectory: true) }
            case "--name": if !args.isEmpty { config.deviceName = args.removeFirst() }
            case "--address": if !args.isEmpty { address = args.removeFirst() }
            case "--seconds": if !args.isEmpty { seconds = Int(args.removeFirst()) ?? seconds }
            case "--qr-file": if !args.isEmpty { qrFile = args.removeFirst() }
            case "--probe-input": probeInput = true
            case "--keychain": useKeychain = true
            case "--help", "-h": print(usage); return
            default: positional.append(a)
            }
        }
        if !useKeychain { config.identityFile = config.dataDirectory.appendingPathComponent("identity.key") }
        let identity: any SigningIdentity
        if let file = config.identityFile {
            identity = try FileIdentityStore.loadOrCreate(at: file)
        } else {
            identity = try IdentityStore.loadOrCreate(service: config.keychainService)
        }
        let store = try HostStore(directory: config.dataDirectory)
        print("prc-controller-cli on \(config.deviceName): identity \(identity.fingerprint)")

        switch command {
        case "discover":
            await discover(config: config, seconds: max(1, seconds == 10 ? 3 : seconds))
        case "hosts":
            for h in store.all { print("  \(h.fingerprint)  \(h.name)  \(h.deviceId)  \(h.addresses.joined(separator: ", "))") }
            if store.all.isEmpty { print("  none") }
        case "pair":
            let text: String
            if let qrFile { text = try String(contentsOfFile: qrFile, encoding: .utf8) }
            else if let first = positional.first { text = first }
            else { print("pair needs the QR payload JSON"); exit(2) }
            let qr = try PairingClient.parse(text)
            print("host \(qr.host_name) fingerprint \((try? DeviceID.fingerprint(deviceId: qr.host_device_id)) ?? "?")")
            print("this controller's fingerprint: \(identity.fingerprint)  <- approve on the host only if it shows this")
            let outcome = try await PairingClient(identity: identity, deviceName: config.deviceName).pair(qr: qr, preferredAddress: address)
            try store.save(outcome.host)
            check(true, "paired with \(outcome.host.name) via \(outcome.address)")
        case "connect":
            guard let needle = positional.first else { print("connect needs a host id prefix or name"); exit(2) }
            guard let host = store.all.first(where: { $0.deviceId.hasPrefix(needle) || $0.name == needle }) else {
                print("no paired host matches \(needle)"); exit(2)
            }
            await connect(host: host, identity: identity, config: config, store: store, address: address, seconds: seconds, probeInput: probeInput)
        default:
            print(usage); exit(2)
        }
        exit(failures == 0 ? 0 : 1)
    }

    /// `prc-controller-cli app …`: drives the running PRC Controller app through its local control channel.
    static func controlApp(_ argsIn: [String]) async {
        var args = argsIn
        var dataDir = ControllerConfig.standard().dataDirectory
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            dataDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            args.removeSubrange(i...(i + 1))
        }
        guard let command = args.first else { print(usage); exit(2) }
        do {
            let response = try await LocalControlClient.send(ControlRequest(command: command, args: Array(args.dropFirst())), controlFile: dataDir.appendingPathComponent("control.json"), timeoutMs: 140_000)
            print(response.message)
            for key in response.data.keys.sorted() { print("  \(key): \(response.data[key]!)") }
            exit(response.ok ? 0 : 1)
        } catch LocalControlError.notRunning {
            print("PRC Controller is not running (no control.json in \(dataDir.path))")
            exit(3)
        } catch {
            print("control error: \(error)")
            exit(3)
        }
    }

    static func discover(config: ControllerConfig, seconds: Int) async {
        let discovery = HostDiscovery(serviceType: config.serviceType)
        let found = Box<[HostDiscovery.DiscoveredHost]>([])
        discovery.onUpdate = { found.set($0) }
        discovery.start()
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        discovery.stop()
        let hosts = found.get()
        print("\(hosts.count) host(s) advertised:")
        for h in hosts {
            let url = await Endpoints.resolve(h.endpoint)
            print("  \(h.name)  \(h.deviceId.prefix(16))…  \(Endpoints.describe(h.endpoint))  -> \(url?.absoluteString ?? "unresolved")")
        }
    }

    static func connect(host: PairedHost, identity: any SigningIdentity, config: ControllerConfig, store: HostStore, address: String?, seconds: Int, probeInput: Bool) async {
        var url: URL? = address.flatMap { Endpoints.url(for: $0) }
        var via = address ?? ""
        if url == nil {
            print("looking for \(host.name) on this network…")
            let discovery = HostDiscovery(serviceType: config.serviceType)
            let found = Box<HostDiscovery.DiscoveredHost?>(nil)
            discovery.onUpdate = { list in if let h = list.first(where: { $0.deviceId == host.deviceId }) { found.set(h) } }
            discovery.start()
            _ = await waitUntil(timeoutMs: 4000, "bonjour") { found.get() != nil }
            discovery.stop()
            if let h = found.get() {
                url = await Endpoints.resolve(h.endpoint)
                via = "Bonjour \(Endpoints.describe(h.endpoint))"
                check(url != nil, "discovered \(host.name) via Bonjour", url?.absoluteString ?? "")
            } else {
                print("  not advertised here; falling back to stored addresses")
            }
        }
        if url == nil {
            let candidates = host.addresses.compactMap { Endpoints.url(for: $0) }
            url = await Endpoints.firstReachable(candidates)
            via = url.map { u in host.addresses.first { Endpoints.url(for: $0) == u } ?? u.absoluteString } ?? ""
            check(url != nil, "reachable address among \(candidates.count) known", via)
        }
        guard let url else { check(false, "no usable address for \(host.name)"); return }
        print("connecting to \(host.name) at \(url.absoluteString) (\(via))")

        let session = SessionClient(.init(identity: identity, host: host, config: config))
        let recorder = Recorder()
        let stream = session.events
        Task { for await e in stream { recorder.record(e) } }
        let counter = Counter()
        await session.attach(renderer: counter)
        await session.connect(url: url)

        let connected = await waitUntil(timeoutMs: 20000, "connected") { recorder.hasState { if case .connected = $0 { return true } else { return false } } }
        guard connected else {
            check(false, "session connected", recorder.hasState { if case .ended = $0 { return true } else { return false } } ? "ended early" : "timeout")
            await session.disconnect()
            return
        }
        check(recorder.hasState { $0 == .authenticating } && recorder.hasState { $0 == .negotiating }, "authenticated and negotiated")
        check(true, "session connected", "path from the controller's view: \(await session.state)")
        store.touch(host.deviceId, at: nowMs(), address: address)

        let gotFrames = await waitUntil(timeoutMs: 15000, "video frames") { counter.snapshot.0 >= 30 }
        let (f0, size) = counter.snapshot
        check(gotFrames, "video frames arriving", "\(f0) frames, \(Int(size.width))x\(Int(size.height))")
        check(await waitUntil(timeoutMs: 8000, "rtt") { recorder.rttCount > 0 }, "ping round trip", recorder.lastRTT.map { "\(Int($0)) ms" } ?? "")
        check(recorder.display != nil, "display info", recorder.display.map { "\($0.width_px)x\($0.height_px) @\($0.scale)x" } ?? "")

        if probeInput {
            // A one-pixel move out and back: proves the injection path without disturbing the host.
            await session.send(.mouseMoveRel(dx: 1, dy: 0))
            try? await Task.sleep(nanoseconds: 50_000_000)
            await session.send(.mouseMoveRel(dx: -1, dy: 0))
            check(true, "sent a one-pixel relative mouse move and back")
        }

        let started = Date()
        var last = counter.snapshot.0
        while Date().timeIntervalSince(started) < Double(seconds) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let (now, s) = counter.snapshot
            print("  \(now - last) fps  \(Int(s.width))x\(Int(s.height))  rtt \(recorder.lastRTT.map { "\(Int($0)) ms" } ?? "-")  \(describe(await session.state))")
            last = now
        }
        let (total, finalSize) = counter.snapshot
        check(total > 0, "streamed for \(seconds) s", "\(total) frames total, final \(Int(finalSize.width))x\(Int(finalSize.height))")
        check(!recorder.hasState { if case .reconnecting = $0 { return true } else { return false } }, "no reconnection needed during the run")

        await session.disconnect()
        check(await waitUntil(timeoutMs: 5000, "ended") { recorder.hasState { if case .ended = $0 { return true } else { return false } } }, "disconnected cleanly")
    }
}
