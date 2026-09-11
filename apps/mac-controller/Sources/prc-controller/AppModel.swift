import AppKit
import Combine
import Foundation
import Network
import PRCControllerCore
import PRCIdentity
import PRCLocalControl
import PRCPeers
import PRCProtocol
import WebRTC

/// What the user can ask for when the link cannot carry everything. Fewer pixels per frame is the
/// most direct way to cut delay on a narrow link: a 1080p frame at 0.9 Mbit/s takes a noticeable
/// fraction of a second to arrive.
enum QualityPreset: String, CaseIterable, Identifiable {
    case auto, p1080, p720, p540, p360

    var id: String { rawValue }

    var maxHeight: Int? {
        switch self {
        case .auto: nil
        case .p1080: 1080
        case .p720: 720
        case .p540: 540
        case .p360: 360
        }
    }

    var label: String {
        switch self {
        case .auto: "Automatic"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p540: "540p"
        case .p360: "360p"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [Peer] = []
    @Published var discovered: [HostDiscovery.DiscoveredHost] = []
    @Published var selectedHostId: String?
    @Published var state: SessionClient.State = .idle
    @Published var rtt: Double?
    @Published var display: DisplayInfo?
    /// Encoded size of the stream as received, as opposed to the host's display size.
    @Published var videoSize: CGSize = .zero
    @Published var sendInput = true
    /// Panel visibility. Only the remote screen is permanent.
    @Published var showSidebar = true
    @Published var showLog = false
    @Published var showTextField = false
    @Published var quality: QualityPreset = .auto { didSet { applyStreamSettings() } }
    /// Sharp text is the default. Smooth motion lets the picture soften to keep the frame rate up.
    @Published var smoothMotion = false { didSet { applyStreamSettings() } }
    @Published var log: [String] = []
    @Published var manualAddress = ""
    @Published var pairingText = ""
    @Published var pairingAddress = ""
    @Published var pairingStatus = ""
    @Published var isPairing = false
    @Published var textToSend = ""

    let config: ControllerConfig
    let identity: any SigningIdentity
    let store: PeerStore
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

    /// Short enough for a header or a status bar.
    var stateSummary: String {
        switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .authenticating: "authenticating"
        case .negotiating: "negotiating"
        case .connected(let path): path
        case .reconnecting: "reconnecting"
        case .ended: "disconnected"
        }
    }

    var placeholderTitle: String {
        switch state {
        case .connected: "Connected"
        case .idle: hosts.isEmpty ? "No hosts paired yet" : "Not connected"
        case .ended: "Disconnected"
        default: Self.describe(state)
        }
    }

    /// The reason a session ended is the one thing worth showing prominently when nothing is on screen.
    var placeholderDetail: String? {
        switch state {
        case .ended(let reason): reason
        case .reconnecting(let why): why
        case .idle where hosts.isEmpty: "Pair with the Mac you want to control, using the button in the sidebar."
        default: nil
        }
    }
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
        if useFileIdentity { config.identityFile = config.dataDirectory.appendingPathComponent("identity.json") }
        self.config = config
        do {
            if let file = config.identityFile {
                identity = try FileBackedIdentityStore.loadOrCreate(at: file)
            } else if CodeSigning.isAdHocSigned {
                // Each ad-hoc build has a new signature; a Keychain item would prompt after every rebuild.
                identity = try FileBackedIdentityStore.loadOrCreate(at: config.dataDirectory.appendingPathComponent("identity.json"))
            } else {
                identity = try IdentityStore.loadOrCreate(service: config.keychainService)
            }
            store = try PeerStore(directory: config.dataDirectory)
        } catch {
            fatalError("cannot initialise identity or host store: \(error)")
        }
        discovery = HostDiscovery(serviceType: config.serviceType)
        hosts = store.hosts
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
        if videoSize != .zero { d["video"] = "\(Int(videoSize.width))x\(Int(videoSize.height))" }
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
        case "probe-input":
            // Two absolute moves in sender order, then back. Proves input reaches the host and that
            // the host's reordering gate is not rejecting everything.
            guard let session, isConnected, let d = display else { return .failure("not connected") }
            await session.send(.mouseMove(displayId: d.display_id, x: 0.5, y: 0.5))
            try? await Task.sleep(nanoseconds: 150_000_000)
            await session.send(.mouseMove(displayId: d.display_id, x: 0.52, y: 0.5))
            return ControlResponse(ok: true, message: "sent two absolute moves to the centre of \(d.display_id)")
        case "panels":
            guard let arg = request.args.first else {
                return ControlResponse(ok: true, message: panelSummary, data: ["sidebar": String(showSidebar), "log": String(showLog), "text": String(showTextField)])
            }
            switch arg {
            case "sidebar": showSidebar.toggle()
            case "log": showLog.toggle()
            case "text": showTextField.toggle()
            default: return .failure("unknown panel \(arg)")
            }
            return ControlResponse(ok: true, message: panelSummary, data: ["sidebar": String(showSidebar), "log": String(showLog), "text": String(showTextField)])
        case "quality":
            guard let arg = request.args.first, let preset = QualityPreset(rawValue: arg) ?? QualityPreset.allCases.first(where: { $0.label.lowercased() == arg.lowercased() }) else {
                return .failure("quality needs one of: \(QualityPreset.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            quality = preset
            if request.args.count > 1 { smoothMotion = request.args[1] == "smooth" }
            return ControlResponse(ok: true, message: "quality \(preset.label)\(smoothMotion ? ", smooth motion" : ", sharp text")")
        case "stats":
            guard let session, isConnected else { return .failure("not connected") }
            guard let v = await session.videoStats() else { return .failure("no video statistics yet") }
            return ControlResponse(ok: true,
                message: "\(v.width)x\(v.height) at \(String(format: "%.0f", v.fps)) fps, \(String(format: "%.0f", v.kbps)) kbps, buffered \(String(format: "%.0f", v.jitterBufferMs)) ms",
                data: ["width": String(v.width), "height": String(v.height), "fps": String(format: "%.1f", v.fps),
                       "kbps": String(format: "%.0f", v.kbps), "packets_lost": String(v.packetsLost),
                       "freezes": String(v.freezeCount), "rtt_ms": rtt.map { String(Int($0)) } ?? "-",
                       "jitter_buffer_ms": String(format: "%.0f", v.jitterBufferMs),
                       "jitter_ms": String(format: "%.1f", v.jitterMs),
                       "quality": quality.label])
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

    private func connect(host: Peer) async {
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
        videoSize = .zero
        let stream = session.events
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .state(let s):
                    self.state = s
                    self.append(Self.describe(s))
                    if case .connected = s {
                        self.store.touchConnected(host.deviceId, at: nowMs(), address: addressUsed)
                        self.hosts = self.store.hosts
                        self.applyStreamSettings()
                    }
                case .rtt(let ms): self.rtt = ms
                case .display(let d): self.display = d
                case .capture(let capture, let detail):
                    self.append("host capture: \(capture.rawValue)\(detail.map { " (\($0))" } ?? "")")
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

    var panelSummary: String {
        "sidebar \(showSidebar ? "on" : "off"), log \(showLog ? "on" : "off"), text \(showTextField ? "on" : "off")"
    }

    /// Sent whenever the choice changes and again on every connect, since a new session starts at
    /// the host's defaults.
    func applyStreamSettings() {
        guard let session, isConnected else { return }
        let height = quality.maxHeight
        let fps = smoothMotion ? 30 : nil
        let prefer: StreamPreference? = smoothMotion ? .latency : .quality
        append("quality: \(quality.label)\(smoothMotion ? ", smooth motion" : "")")
        Task { await session.send(.streamSettings(maxHeight: height, maxFps: fps, prefer: prefer)) }
    }

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
                let h = outcome.host
                try store.pair(deviceId: h.deviceId, publicKey: h.publicKey, name: h.name, type: h.type,
                               mayControlUs: h.mayControlUs, weMayControl: h.weMayControl,
                               addresses: h.addresses, rendezvousURL: h.rendezvousURL, now: nowMs())
                hosts = store.hosts
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
        // Forgetting from the controller side only withdraws our right to control it; if that Mac
        // is also allowed to control us, that permission is managed on the hosting side.
        try? store.setWeMayControl(id, false)
        hosts = store.hosts
        if selectedHostId == id { selectedHostId = hosts.first?.deviceId }
    }
}
