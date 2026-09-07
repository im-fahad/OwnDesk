import AppKit
import Combine
import Foundation
import Network
import PRCControllerCore
import PRCIdentity
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
        if url == nil, let first = host.addresses.first(where: { Endpoints.url(for: $0) != nil }) {
            url = Endpoints.url(for: first)
            addressUsed = first
        }
        guard let url else { append("no address for \(host.name); enter one"); return }
        append("connecting to \(host.name) at \(url.absoluteString)")
        let session = SessionClient(.init(identity: identity, host: host, config: config))
        self.session = session
        rtt = nil
        display = nil
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
