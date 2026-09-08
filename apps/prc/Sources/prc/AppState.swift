import AppKit
import Combine
import Foundation
import Network
import PRCAgentCore
import PRCControllerCore
import PRCIdentity
import PRCLocalControl
import PRCPeers
import PRCProtocol
import UserNotifications
import WebRTC

/// What the user can ask for when the link cannot carry everything. Fewer pixels per frame is the
/// most direct way to cut delay on a narrow link.
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

/// Both cores export a `nowMs`, so this app uses its own to keep call sites unambiguous.
func currentMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// One model for both halves of the app. A Mac can host, control, or do both, and the two share an
/// identity and a peer list so everyone else sees a single device.
@MainActor
final class AppState: ObservableObject {

    // MARK: Hosting, the incoming half

    struct IncomingSession: Equatable {
        var deviceName: String
        var phase: String
        var path: String?
        var since: Date
    }

    struct PendingRequest: Equatable {
        var deviceId: String
        var name: String
        var type: DeviceType
        var fingerprint: String
    }

    struct PairingInvite {
        var qr: QRPayload
        var payloadText: String
        var image: NSImage?
        var expiresAt: Date
    }

    @Published var hosting = false
    @Published var hostPort: UInt16 = 0
    @Published var hostAddresses: [String] = []
    @Published var incoming: IncomingSession?
    @Published var pendingRequest: PendingRequest?
    @Published var invite: PairingInvite?
    @Published var pairingOutcome: String?
    @Published var screenRecording = Permissions.screenRecordingGranted
    @Published var accessibility = Permissions.accessibilityGranted

    // MARK: Controlling, the outgoing half

    @Published var peerList: [Peer] = []
    @Published var discovered: [HostDiscovery.DiscoveredHost] = []
    @Published var selectedPeerId: String?
    @Published var state: SessionClient.State = .idle
    @Published var rtt: Double?
    @Published var display: DisplayInfo?
    @Published var videoSize: CGSize = .zero
    @Published var quality: QualityPreset = .auto { didSet { applyStreamSettings() } }
    @Published var smoothMotion = false { didSet { applyStreamSettings() } }
    @Published var sendInput = true
    @Published var manualAddress = ""
    @Published var textToSend = ""

    // MARK: Pairing input, shared

    @Published var pairingText = ""
    @Published var pairingAddress = ""
    @Published var pairingStatus = ""
    @Published var isPairing = false

    // MARK: Chrome

    @Published var showSidebar = true
    @Published var showLog = false
    @Published var showTextField = false
    @Published var log: [String] = []
    @Published var lastMessage = ""

    let config: AppConfiguration
    let identity: any SigningIdentity
    let peers: PeerStore
    private var agent: Agent?
    private var agentEvents: Task<Void, Never>?
    private var session: SessionClient?
    private var sessionEvents: Task<Void, Never>?
    private let discovery: HostDiscovery
    private var control: LocalControlServer?
    private var permissionTimer: Timer?
    private var pendingRenderer: RTCVideoRenderer?
    private var lastMoveAt: TimeInterval = 0
    private var pendingMove: DataChannelMessage?
    private var moveFlush: DispatchWorkItem?
    private let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    var fingerprint: String { identity.fingerprint }
    var isConnected: Bool { if case .connected = state { return true } else { return false } }
    var isBusy: Bool {
        switch state {
        case .idle, .ended: false
        default: true
        }
    }

    init(config: AppConfiguration) {
        self.config = config
        do {
            identity = try config.loadIdentity()
            peers = try PeerStore(directory: config.dataDirectory)
        } catch {
            let alert = NSAlert()
            alert.messageText = "PRC cannot start"
            alert.informativeText = "\(error)"
            alert.runModal()
            exit(1)
        }
        // Whichever of the two old apps ran on this Mac, its pairings come forward.
        PeerMigration.importLegacy(into: peers, agentDirectory: config.legacyAgentDirectory,
                                   controllerDirectory: config.legacyControllerDirectory, now: currentMs())
        discovery = HostDiscovery(serviceType: AgentConfig.serviceType)
        peerList = peers.all
        selectedPeerId = peers.hosts.first?.deviceId
        discovery.onUpdate = { [weak self] found in
            Task { @MainActor in self?.discovered = found }
        }
        discovery.start()
        append("identity \(identity.fingerprint) ready")

        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.screenRecording = Permissions.screenRecordingGranted
                self?.accessibility = Permissions.accessibilityGranted
            }
        }
        let server = LocalControlServer(controlFile: config.dataDirectory.appendingPathComponent("control.json")) { [weak self] request in
            guard let self else { return .failure("app is shutting down") }
            return await self.handleControl(request)
        }
        try? server.start()
        control = server

        if config.hostingEnabled { setHosting(true) }
    }

    func append(_ line: String) {
        log.insert("\(Self.timeFormatter.string(from: Date()))  \(line)", at: 0)
        if log.count > 300 { log.removeLast() }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Hosting

    /// The agent is built only when hosting is first switched on, so a Mac used purely as a
    /// controller never touches screen capture and is never asked for those permissions.
    func setHosting(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: AppConfiguration.hostingDefaultsKey)
        guard on != hosting || (on && agent == nil) else { return }
        if on {
            do {
                let agent = try agent ?? makeAgent()
                self.agent = agent
                try agent.start()
                hosting = true
                append("hosting on")
                requestHostPermissions()
            } catch {
                lastMessage = "Could not start hosting: \(error)"
                append(lastMessage)
                hosting = false
            }
        } else {
            let agent = self.agent
            hosting = false
            incoming = nil
            invite = nil
            pendingRequest = nil
            append("hosting off")
            Task { try? await agent?.setRemoteAccess(false) }
        }
    }

    private func makeAgent() throws -> Agent {
        let agent = try Agent(config: config.agentConfig(), identity: identity, peers: peers)
        let stream = agent.events
        agentEvents?.cancel()
        agentEvents = Task { [weak self] in
            for await event in stream { self?.handleAgent(event) }
        }
        return agent
    }

    private func requestHostPermissions() {
        if !config.syntheticScreen, !Permissions.screenRecordingGranted { Permissions.requestScreenRecording() }
        if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
    }

    private func handleAgent(_ event: AgentEvent) {
        switch event {
        case .listening(let port, let addresses):
            hostPort = port
            hostAddresses = addresses
        case .pairingOpened(let qr):
            let data = (try? JSONEncoder().encode(qr)) ?? Data()
            invite = PairingInvite(qr: qr, payloadText: String(decoding: data, as: UTF8.self),
                                   image: Self.qrImage(data),
                                   expiresAt: Date(timeIntervalSince1970: Double(qr.expires_at) / 1000))
            pendingRequest = nil
            pairingOutcome = nil
        case .pairingRequest(let deviceId, let name, let type, let fingerprint):
            pendingRequest = PendingRequest(deviceId: deviceId, name: name, type: type, fingerprint: fingerprint)
            NSApp.activate(ignoringOtherApps: true)
            notify("Pairing request", "\(name) wants to pair. Compare fingerprints, then approve or deny.")
        case .pairingCompleted(_, let name):
            refreshPeers()
            pairingOutcome = "Paired with \(name)."
            pendingRequest = nil
            append("paired with \(name)")
        case .pairingFailed(let reason):
            pairingOutcome = "Pairing not completed: \(reason)."
            pendingRequest = nil
        case .pairingClosed:
            invite = nil
            pendingRequest = nil
        case .sessionRequested(_, let name):
            incoming = IncomingSession(deviceName: name, phase: "authenticating", path: nil, since: Date())
        case .sessionAuthenticated(_, let name):
            incoming = IncomingSession(deviceName: name, phase: "negotiating", path: nil, since: incoming?.since ?? Date())
            refreshPeers()
        case .sessionConnected(let name, let path):
            incoming = IncomingSession(deviceName: name, phase: "connected", path: path, since: incoming?.since ?? Date())
            notify("Someone is controlling this Mac", "\(name) (\(path))")
            append("\(name) is controlling this Mac: \(path)")
        case .sessionEnded(let reason):
            if let s = incoming { notify("Remote session ended", "\(s.deviceName): \(reason.rawValue)") }
            incoming = nil
            append("incoming session ended: \(reason.rawValue)")
        case .rejected(let deviceId, let reason):
            append("rejected \(String(deviceId.prefix(12)))…: \(reason.rawValue)")
        case .remoteAccessChanged(let on):
            hosting = on
            if !on { incoming = nil }
        case .deviceRevoked:
            refreshPeers()
        case .warning(let text), .info(let text):
            lastMessage = text
            append(text)
        }
    }

    func refreshPeers() {
        peerList = peers.all
        if selectedPeerId == nil { selectedPeerId = peers.hosts.first?.deviceId }
    }

    var hostablePeers: [Peer] { peerList.filter(\.weMayControl) }

    func discoveredPeer(for deviceId: String) -> HostDiscovery.DiscoveredHost? {
        discovered.first { $0.deviceId == deviceId }
    }

    // MARK: Pairing, either direction

    /// Show a code for another device to scan or paste. Only a hosting Mac can offer one, because
    /// pairing runs over the agent's signalling endpoint.
    func offerPairing() {
        guard hosting, let agent else {
            pairingStatus = "Turn on hosting first: a pairing code is served by the hosting half."
            return
        }
        Task { _ = await agent.coordinator.openPairing() }
    }

    func cancelPairing() {
        guard let agent else { return }
        Task { await agent.coordinator.cancelPairing() }
    }

    func approvePairing() {
        guard let agent else { return }
        Task { await agent.coordinator.resolvePairing(approved: true) }
    }

    func denyPairing() {
        guard let agent else { return }
        Task { await agent.coordinator.resolvePairing(approved: false) }
    }

    /// Use a code shown by another Mac.
    func usePairingCode() {
        guard !isPairing else { return }
        let qr: QRPayload
        do { qr = try PairingClient.parse(pairingText) } catch { pairingStatus = "\(error)"; return }
        isPairing = true
        pairingStatus = "Approve on \(qr.host_name) if it shows this Mac's fingerprint \(fingerprint)."
        let client = PairingClient(identity: identity, deviceName: config.deviceName)
        let preferred = pairingAddress
        Task {
            do {
                let outcome = try await client.pair(qr: qr, preferredAddress: preferred.isEmpty ? nil : preferred)
                let h = outcome.host
                try peers.pair(deviceId: h.deviceId, publicKey: h.publicKey, name: h.name, type: h.type,
                               mayControlUs: h.mayControlUs, weMayControl: h.weMayControl,
                               addresses: h.addresses, rendezvousURL: h.rendezvousURL, now: currentMs())
                refreshPeers()
                selectedPeerId = h.deviceId
                pairingStatus = "Paired with \(h.name)."
                pairingText = ""
                append("paired with \(h.name)")
            } catch {
                pairingStatus = "Pairing failed: \(error)"
                append("pairing failed: \(error)")
            }
            isPairing = false
        }
    }

    // MARK: Permissions per direction

    func setMayControlUs(_ deviceId: String, _ allowed: Bool) {
        try? peers.setMayControlUs(deviceId, allowed)
        refreshPeers()
        if !allowed, let agent, incoming != nil {
            Task { await agent.coordinator.revoke(deviceId: deviceId) }
        }
    }

    func setWeMayControl(_ deviceId: String, _ allowed: Bool) {
        try? peers.setWeMayControl(deviceId, allowed)
        refreshPeers()
        if selectedPeerId == deviceId, !allowed { selectedPeerId = peers.hosts.first?.deviceId }
    }

    func forget(_ deviceId: String) {
        try? peers.forget(deviceId)
        refreshPeers()
        if selectedPeerId == deviceId { selectedPeerId = peers.hosts.first?.deviceId }
    }

    func endIncoming() {
        guard let agent else { return }
        Task { await agent.coordinator.endSession(reason: .user) }
    }

    // MARK: Controlling

    func connect() {
        guard let id = selectedPeerId, let peer = peers.host(id), !isBusy else { return }
        state = .connecting
        rtt = nil
        display = nil
        videoSize = .zero
        Task { await connect(to: peer) }
    }

    private func connect(to peer: Peer) async {
        var url: URL?
        var addressUsed: String?
        if !manualAddress.isEmpty {
            url = Endpoints.url(for: manualAddress)
            addressUsed = manualAddress
            if url == nil { append("bad address: \(manualAddress)"); state = .ended("bad address"); return }
        } else if let found = discoveredPeer(for: peer.deviceId) {
            append("resolving \(Endpoints.describe(found.endpoint))")
            url = await Endpoints.resolve(found.endpoint)
        }
        if url == nil {
            let candidates = peer.addresses.compactMap { Endpoints.url(for: $0) }
            if candidates.count > 1 { append("trying \(candidates.count) known addresses") }
            url = await Endpoints.firstReachable(candidates)
            addressUsed = url.map { u in peer.addresses.first { Endpoints.url(for: $0) == u } ?? u.absoluteString }
            if url == nil, !candidates.isEmpty { append("none of \(peer.name)'s known addresses answered") }
        }
        guard let url else { append("no address for \(peer.name)"); state = .ended("no address"); return }
        append("connecting to \(peer.name) \(peer.fingerprint) at \(url.absoluteString)")

        let session = SessionClient(.init(identity: identity, host: peer, config: config.controllerConfig()))
        self.session = session
        let stream = session.events
        sessionEvents?.cancel()
        sessionEvents = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .state(let s):
                    self.state = s
                    self.append(Self.describe(s))
                    if case .connected = s {
                        self.peers.touchConnected(peer.deviceId, at: currentMs(), address: addressUsed)
                        self.refreshPeers()
                        self.applyStreamSettings()
                    }
                case .rtt(let ms): self.rtt = ms
                case .display(let d): self.display = d
                case .remoteVideo: self.append("video track received")
                case .log(let text): self.append(text)
                }
            }
        }
        if let renderer = pendingRenderer { await session.attach(renderer: renderer) }
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
        case .idle: "idle"
        case .connecting: "connecting"
        case .authenticating: "authenticating"
        case .negotiating: "negotiating WebRTC"
        case .connected(let path): "connected: \(path)"
        case .reconnecting(let why): "reconnecting (\(why))"
        case .ended(let reason): "ended: \(reason)"
        }
    }

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
        case .idle: hostablePeers.isEmpty ? "No Macs paired yet" : "Not connected"
        case .ended: "Disconnected"
        default: Self.describe(state)
        }
    }

    var placeholderDetail: String? {
        switch state {
        case .ended(let reason): reason
        case .reconnecting(let why): why
        case .idle where hostablePeers.isEmpty: "Pair with the Mac you want to control, using the button in the sidebar."
        default: nil
        }
    }

    func applyStreamSettings() {
        guard let session, isConnected else { return }
        let prefer: StreamPreference? = smoothMotion ? .latency : .quality
        append("quality: \(quality.label)\(smoothMotion ? ", smooth motion" : "")")
        Task { await session.send(.streamSettings(maxHeight: quality.maxHeight, maxFps: smoothMotion ? 30 : nil, prefer: prefer)) }
    }

    // MARK: Input

    func send(_ message: DataChannelMessage) {
        guard sendInput, isConnected, let session else { return }
        if case .mouseMove = message {
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

    func sendShortcut(_ code: String, modifiers: [Modifier]) {
        guard let session else { return }
        let codes = modifiers.map { m -> String in
            switch m {
            case .meta: "MetaLeft"
            case .shift: "ShiftLeft"
            case .control: "ControlLeft"
            case .alt: "AltLeft"
            case .capslock: "CapsLock"
            }
        }
        Task {
            var held: [Modifier] = []
            for (m, c) in zip(modifiers, codes) {
                held.append(m)
                await session.send(.keyDown(code: c, modifiers: held, repeat: false))
            }
            await session.send(.keyDown(code: code, modifiers: modifiers, repeat: false))
            await session.send(.keyUp(code: code, modifiers: modifiers))
            for (m, c) in zip(modifiers, codes).reversed() {
                held.removeAll { $0 == m }
                await session.send(.keyUp(code: c, modifiers: held))
            }
        }
    }

    // MARK: Misc

    // MARK: Local control, for scripts and tests

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
            "fingerprint": fingerprint,
            "device_id": identity.deviceId,
            "hosting": hosting ? "on" : "off",
            "host_port": String(hostPort),
            "host_addresses": hostAddresses.joined(separator: ","),
            "peers": String(peerList.count),
            "controllable": String(hostablePeers.count),
            "state": Self.describe(state),
            "screen_recording": screenRecording ? "granted" : "missing",
            "accessibility": accessibility ? "granted" : "missing",
        ]
        if let i = incoming { d["incoming"] = "\(i.deviceName): \(i.path ?? i.phase)" }
        if let rtt { d["rtt_ms"] = String(Int(rtt)) }
        if let display { d["display"] = "\(display.width_px)x\(display.height_px)" }
        if videoSize != .zero { d["video"] = "\(Int(videoSize.width))x\(Int(videoSize.height))" }
        if let id = selectedPeerId, let p = peers.peer(id) { d["selected"] = p.name }
        return d
    }

    func handleControl(_ request: ControlRequest) async -> ControlResponse {
        switch request.command {
        case "status":
            return ControlResponse(ok: true, message: "hosting \(hosting ? "on" : "off"), \(Self.describe(state))", data: statusData)
        case "peers":
            let lines = peerList.map { p in
                "\(p.fingerprint)  \(p.name)  \(p.deviceId)  \(p.mayControlUs ? "may-control-us " : "")\(p.weMayControl ? "we-may-control" : "")"
            }
            return ControlResponse(ok: true, message: lines.isEmpty ? "none" : lines.joined(separator: "\n"), data: ["count": String(peerList.count)])
        case "hosting":
            guard let arg = request.args.first, ["on", "off"].contains(arg) else { return .failure("hosting needs on or off") }
            setHosting(arg == "on")
            _ = await waitUntil(4000, { hosting == (arg == "on") })
            return ControlResponse(ok: true, message: "hosting \(hosting ? "on" : "off")", data: statusData)
        case "offer-pairing":
            offerPairing()
            guard await waitUntil(4000, { invite != nil }), let invite else { return .failure(pairingStatus.isEmpty ? "pairing did not open" : pairingStatus) }
            return ControlResponse(ok: true, message: invite.payloadText, data: ["fingerprint": fingerprint])
        case "pending":
            guard await waitUntil(Int(request.args.first ?? "") ?? 120_000, { pendingRequest != nil || invite == nil }), let p = pendingRequest else {
                return .failure(invite == nil ? "pairing window closed" : "no request yet")
            }
            return ControlResponse(ok: true, message: "\(p.name) fingerprint \(p.fingerprint)", data: ["name": p.name, "fingerprint": p.fingerprint, "device_id": p.deviceId])
        case "approve", "deny":
            guard pendingRequest != nil else { return .failure("no pending pairing request") }
            pairingOutcome = nil
            request.command == "approve" ? approvePairing() : denyPairing()
            _ = await waitUntil(5000, { pairingOutcome != nil })
            return ControlResponse(ok: pairingOutcome?.hasPrefix("Paired") == true || request.command == "deny", message: pairingOutcome ?? "no outcome")
        case "pair":
            guard var text = request.args.first else { return .failure("pair needs the payload text or @file") }
            if text.hasPrefix("@") { text = (try? String(contentsOfFile: String(text.dropFirst()), encoding: .utf8)) ?? "" }
            pairingText = text
            pairingAddress = request.args.count > 1 ? request.args[1] : ""
            usePairingCode()
            guard isPairing else { return .failure(pairingStatus) }
            _ = await waitUntil(135_000, { !isPairing })
            return ControlResponse(ok: pairingStatus.hasPrefix("Paired"), message: pairingStatus)
        case "connect":
            guard let needle = request.args.first else { return .failure("connect needs a peer name or id prefix") }
            guard let peer = hostablePeers.first(where: { $0.deviceId.hasPrefix(needle.lowercased()) || $0.name == needle || $0.fingerprint.hasPrefix(needle.uppercased()) }) else {
                return .failure("no peer this Mac may control matches \(needle)")
            }
            selectedPeerId = peer.deviceId
            manualAddress = request.args.count > 1 ? request.args[1] : ""
            connect()
            _ = await waitUntil(30_000, { if case .connected = state { return true }; if case .ended = state { return true }; return false })
            return ControlResponse(ok: isConnected, message: Self.describe(state), data: statusData)
        case "disconnect":
            disconnect()
            _ = await waitUntil(5000, { !isBusy })
            return ControlResponse(ok: !isBusy, message: Self.describe(state), data: statusData)
        case "end-incoming":
            endIncoming()
            _ = await waitUntil(5000, { incoming == nil })
            return ControlResponse(ok: incoming == nil, message: incoming == nil ? "incoming session ended" : "still active")
        case "allow":
            guard request.args.count >= 2, let peer = peerList.first(where: { $0.deviceId.hasPrefix(request.args[0].lowercased()) || $0.fingerprint.hasPrefix(request.args[0].uppercased()) }) else {
                return .failure("allow needs <peer> <control-us|we-control> [on|off]")
            }
            let on = request.args.count < 3 || request.args[2] == "on"
            if request.args[1] == "control-us" { setMayControlUs(peer.deviceId, on) } else { setWeMayControl(peer.deviceId, on) }
            let after = peers.peer(peer.deviceId)
            return ControlResponse(ok: true, message: "\(peer.name): may-control-us \(after?.mayControlUs ?? false), we-may-control \(after?.weMayControl ?? false)")
        case "forget":
            guard let needle = request.args.first, let peer = peerList.first(where: { $0.deviceId.hasPrefix(needle.lowercased()) || $0.fingerprint.hasPrefix(needle.uppercased()) }) else {
                return .failure("forget needs a peer id or fingerprint prefix")
            }
            forget(peer.deviceId)
            return ControlResponse(ok: true, message: "forgot \(peer.name)")
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
            return ControlResponse(ok: true, message: panelSummary)
        case "quality":
            guard let arg = request.args.first, let preset = QualityPreset(rawValue: arg) else {
                return .failure("quality needs one of: \(QualityPreset.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            quality = preset
            if request.args.count > 1 { smoothMotion = request.args[1] == "smooth" }
            return ControlResponse(ok: true, message: "quality \(preset.label)\(smoothMotion ? ", smooth motion" : ", sharp text")")
        case "quit":
            Task { quit() }
            return ControlResponse(ok: true, message: "quitting")
        default:
            return .failure("unknown command \(request.command)")
        }
    }

    var panelSummary: String {
        "sidebar \(showSidebar ? "on" : "off"), log \(showLog ? "on" : "off"), text \(showTextField ? "on" : "off")"
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func copyInvite() {
        guard let invite else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite.payloadText, forType: .string)
    }

    func quit() {
        let agent = self.agent
        Task {
            await agent?.stop()
            NSApp.terminate(nil)
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func qrImage(_ data: Data, scale: CGFloat = 6) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
