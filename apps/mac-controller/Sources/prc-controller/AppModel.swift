import AppKit
import Combine
import Foundation
import Network
import PRCControllerCore
import PRCIdentity
import PRCLocalControl
import PRCProtocol
import WebRTC

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [PairedHost] = []
    @Published var discovered: [HostDiscovery.DiscoveredHost] = []
    @Published var selectedHostId: String?
    @Published var state: SessionClient.State = .idle
    @Published var rtt: Double?
    @Published var display: DisplayInfo?
    @Published var sendInput = true
    @Published var log: [String] = []
    @Published var manualAddress = ""
    @Published var pairingText = ""
    @Published var pairingAddress = ""
    @Published var pairingStatus = ""
    @Published var isPairing = false
    @Published var textToSend = ""

    let config: ControllerConfig
    let identity: any SigningIdentity
    let store: HostStore
    private let discovery: HostDiscovery
    private var control: LocalControlServer?
    private var session: SessionClient?
    private var eventsTask: Task<Void, Never>?
    private var pendingRenderer: RTCVideoRenderer?
    private var lastMoveAt: TimeInterval = 0
    private var pendingMove: DataChannelMessage?
    private var moveFlush: DispatchWorkItem?

    var fingerprint: String { identity.fingerprint }
    var isConnected: Bool { if case .connected = state { return true } else { return false } }
    var isBusy: Bool {
        switch state {
        case .idle, .ended: return false
        default: return true
        }
    }

    init() {
        var config = ControllerConfig.standard()
        var useFileIdentity = false
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--data-dir": if !args.isEmpty { config.dataDirectory = URL(fileURLWithPath: args.removeFirst(), isDirectory: true) }
            case "--name": if !args.isEmpty { config.deviceName = args.removeFirst() }
            case "--file-identity": useFileIdentity = true
            default: break
            }
        }
        if useFileIdentity { config.identityFile = config.dataDirectory.appendingPathComponent("identity.key") }
        self.config = config
        do {
            if let file = config.identityFile {
                identity = try FileIdentityStore.loadOrCreate(at: file)
            } else if CodeSigning.isAdHocSigned {
                // Each ad-hoc build has a new signature; a Keychain item would prompt after every rebuild.
                identity = try FileBackedIdentityStore.loadOrCreate(at: config.dataDirectory.appendingPathComponent("identity.json"))
            } else {
                identity = try IdentityStore.loadOrCreate(service: config.keychainService)
            }
            store = try HostStore(directory: config.dataDirectory)
        } catch {
            fatalError("cannot initialise identity or host store: \(error)")
        }
        discovery = HostDiscovery(serviceType: config.serviceType)
        hosts = store.all
        selectedHostId = hosts.first?.deviceId
        discovery.onUpdate = { [weak self] found in
            Task { @MainActor in self?.discovered = found }
        }
        discovery.start()
        append("identity \(identity.fingerprint) ready")

        let server = LocalControlServer(controlFile: config.dataDirectory.appendingPathComponent("control.json")) { [weak self] request in
            guard let self else { return .failure("app is shutting down") }
            return await self.handleControl(request)
        }
        try? server.start()
        control = server
    }

    // MARK: Local control (prc-controller-cli app …)

    private func waitUntil(_ ms: Int, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    var statusData: [String: String] {
        var d: [String: String] = [
            "state": Self.describe(state),
            "fingerprint": fingerprint,
            "device_id": identity.deviceId,
            "hosts": String(hosts.count),
            "nearby": discovered.map(\.name).joined(separator: ","),
        ]
        if let rtt { d["rtt_ms"] = String(Int(rtt)) }
        if let display { d["display"] = "\(display.width_px)x\(display.height_px)" }
        if let id = selectedHostId, let h = store.host(id) { d["selected"] = h.name }
        return d
    }

    func handleControl(_ request: ControlRequest) async -> ControlResponse {
        switch request.command {
        case "status":
            return ControlResponse(ok: true, message: Self.describe(state), data: statusData)
        case "hosts":
            let lines = hosts.map { "\($0.fingerprint)  \($0.name)  \($0.deviceId)  \(discoveredHost(for: $0.deviceId) != nil ? "nearby" : "")" }
            return ControlResponse(ok: true, message: lines.isEmpty ? "none" : lines.joined(separator: "\n"), data: ["count": String(hosts.count)])
        case "pair":
            guard var text = request.args.first else { return .failure("pair needs the payload text or @file") }
            if text.hasPrefix("@") { text = (try? String(contentsOfFile: String(text.dropFirst()), encoding: .utf8)) ?? "" }
            guard !isPairing else { return .failure("a pairing is already in progress") }
            pairingText = text
            pairingAddress = request.args.count > 1 ? request.args[1] : ""
            pair()
            guard isPairing else { return .failure(pairingStatus) }
            _ = await waitUntil(135_000, { !isPairing })
            return ControlResponse(ok: pairingStatus.hasPrefix("Paired"), message: pairingStatus, data: ["fingerprint": fingerprint])
        case "connect":
            guard let needle = request.args.first else { return .failure("connect needs a host name or id prefix") }
            guard let host = hosts.first(where: { $0.deviceId.hasPrefix(needle.lowercased()) || $0.name == needle || $0.fingerprint.hasPrefix(needle.uppercased()) }) else {
                return .failure("no paired host matches \(needle)")
            }
            selectedHostId = host.deviceId
            manualAddress = request.args.count > 1 ? request.args[1] : ""
            connect()
            _ = await waitUntil(30_000, { if case .connected = state { return true }; if case .ended = state { return true }; return false })
            return ControlResponse(ok: isConnected, message: Self.describe(state), data: statusData)
        case "disconnect":
            disconnect()
            _ = await waitUntil(5000, { !isBusy })
            return ControlResponse(ok: !isBusy, message: Self.describe(state), data: statusData)
        case "forget":
            guard let needle = request.args.first else { return .failure("forget needs a host id or fingerprint prefix") }
            let matches = hosts.filter { $0.deviceId.hasPrefix(needle.lowercased()) || $0.fingerprint.hasPrefix(needle.uppercased()) }
            guard matches.count == 1 else { return .failure("\(matches.count) hosts match") }
            forget(matches[0].deviceId)
            return ControlResponse(ok: true, message: "forgot \(matches[0].name) \(matches[0].fingerprint)", data: ["hosts": String(hosts.count)])
        case "quit":
            Task { NSApp.terminate(nil) }
            return ControlResponse(ok: true, message: "quitting")
        default:
            return .failure("unknown command \(request.command)")
        }
    }

    func append(_ line: String) {
        log.insert("\(Self.timeFormatter.string(from: Date()))  \(line)", at: 0)
        if log.count > 200 { log.removeLast() }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func discoveredHost(for id: String) -> HostDiscovery.DiscoveredHost? {
        discovered.first { $0.deviceId == id }
    }

    // MARK: Session

    func connect() {
        guard let id = selectedHostId, let host = store.host(id), !isBusy else { return }
        state = .connecting
        rtt = nil
        display = nil
        Task { await self.connect(host: host) }
    }

    private func connect(host: PairedHost) async {
        var url: URL? = nil
        var addressUsed: String? = nil
        if !manualAddress.isEmpty {
            url = Endpoints.url(for: manualAddress)
            addressUsed = manualAddress
            if url == nil { append("bad address: \(manualAddress)"); return }
        } else if let found = discoveredHost(for: host.deviceId) {
            append("resolving \(Endpoints.describe(found.endpoint))")
            url = await Endpoints.resolve(found.endpoint)
            if url == nil { append("could not resolve \(host.name) on this network") }
        }
        if url == nil {
            // Try every address the host advertised at pairing time at once and take the first that
            // answers, so the same button works at home and away without typing anything.
            let candidates = host.addresses.compactMap { Endpoints.url(for: $0) }
            if candidates.count > 1 { append("trying \(candidates.count) known addresses") }
            url = await Endpoints.firstReachable(candidates)
            addressUsed = url.map { u in host.addresses.first { Endpoints.url(for: $0) == u } ?? u.absoluteString }
            if url == nil, !candidates.isEmpty {
                append("none of \(host.name)'s known addresses answered on this network")
            }
        }
        guard let url else { append("no address for \(host.name); enter one"); state = .ended("no address"); return }
        append("connecting to \(host.name) \(host.fingerprint) at \(url.absoluteString)")
        let session = SessionClient(.init(identity: identity, host: host, config: config))
        self.session = session
        let stream = session.events
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .state(let s):
                    self.state = s
                    self.append(Self.describe(s))
                    if case .connected = s { self.store.touch(host.deviceId, at: nowMs(), address: addressUsed); self.hosts = self.store.all }
                case .rtt(let ms): self.rtt = ms
                case .display(let d): self.display = d
                case .remoteVideo: self.append("video track received")
                case .log(let text): self.append(text)
                }
            }
        }
        if let renderer = pendingRenderer { Task { await session.attach(renderer: renderer) } }
        await session.connect(url: url)
    }

    func disconnect() {
        guard let session else { return }
        Task { await session.disconnect() }
    }

    func attach(renderer: RTCVideoRenderer) {
        pendingRenderer = renderer
        if let session { Task { await session.attach(renderer: renderer) } }
    }

    static func describe(_ s: SessionClient.State) -> String {
        switch s {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .authenticating: return "authenticating"
        case .negotiating: return "negotiating WebRTC"
        case .connected(let path): return "connected: \(path)"
        case .reconnecting(let why): return "reconnecting (\(why))"
        case .ended(let reason): return "ended: \(reason)"
        }
    }

    // MARK: Input

    func send(_ message: DataChannelMessage) {
        guard sendInput, isConnected, let session else { return }
        if case .mouseMove = message {
            // Coalesce to one move per 4 ms (spec section 12.2).
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastMoveAt < 0.004 {
                pendingMove = message
                if moveFlush == nil {
                    let item = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.moveFlush = nil
                        if let m = self.pendingMove { self.pendingMove = nil; self.send(m) }
                    }
                    moveFlush = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4), execute: item)
                }
                return
            }
            lastMoveAt = now
        }
        Task { await session.send(message) }
    }

    func sendText() {
        let text = textToSend
        guard !text.isEmpty, let session else { return }
        textToSend = ""
        Task { await session.send(.text(text)) }
    }

    /// Shortcuts the window cannot capture itself, sent as explicit key sequences.
    func sendShortcut(_ code: String, modifiers: [Modifier]) {
        guard let session else { return }
        let modifierCodes = modifiers.map { m -> String in
            switch m {
            case .meta: return "MetaLeft"
            case .shift: return "ShiftLeft"
            case .control: return "ControlLeft"
            case .alt: return "AltLeft"
            case .capslock: return "CapsLock"
            }
        }
        Task {
            var held: [Modifier] = []
            for (m, c) in zip(modifiers, modifierCodes) {
                held.append(m)
                await session.send(.keyDown(code: c, modifiers: held, repeat: false))
            }
            await session.send(.keyDown(code: code, modifiers: modifiers, repeat: false))
            await session.send(.keyUp(code: code, modifiers: modifiers))
            for (m, c) in zip(modifiers, modifierCodes).reversed() {
                held.removeAll { $0 == m }
                await session.send(.keyUp(code: c, modifiers: held))
            }
        }
    }

    // MARK: Pairing

    func pair() {
        guard !isPairing else { return }
        let qr: QRPayload
        do { qr = try PairingClient.parse(pairingText) } catch { pairingStatus = "\(error)"; return }
        isPairing = true
        pairingStatus = "Approve on \(qr.host_name) if it shows your fingerprint \(identity.fingerprint). Its fingerprint is \((try? DeviceID.fingerprint(deviceId: qr.host_device_id)) ?? "?")."
        let client = PairingClient(identity: identity, deviceName: config.deviceName)
        let preferred = pairingAddress
        Task {
            do {
                let outcome = try await client.pair(qr: qr, preferredAddress: preferred.isEmpty ? nil : preferred)
                try store.save(outcome.host)
                hosts = store.all
                selectedHostId = outcome.host.deviceId
                pairingStatus = "Paired with \(outcome.host.name)."
                pairingText = ""
                append("paired with \(outcome.host.name)")
            } catch {
                pairingStatus = "Pairing failed: \(error)"
                append("pairing failed: \(error)")
            }
            isPairing = false
        }
    }

    func forget(_ id: String) {
        try? store.forget(id)
        hosts = store.all
        if selectedHostId == id { selectedHostId = hosts.first?.deviceId }
    }
}
