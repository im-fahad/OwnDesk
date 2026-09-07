import AppKit
import Combine
import CoreImage
import Foundation
import PRCAgentCore
import PRCIdentity
import PRCLocalControl
import PRCProtocol
import UserNotifications

@MainActor
final class AgentAppModel: ObservableObject {
    struct SessionInfo: Equatable {
        var deviceName: String
        var phase: String
        var path: String?
        var since: Date
    }

    struct PairingInfo {
        var qr: QRPayload
        var payloadText: String
        var image: NSImage?
        var expiresAt: Date
    }

    struct PendingRequest: Equatable {
        var deviceId: String
        var name: String
        var type: DeviceType
        var fingerprint: String
    }

    @Published var remoteAccess = true
    @Published var port: UInt16 = 0
    @Published var addresses: [String] = []
    @Published var devices: [TrustedDevice] = []
    @Published var session: SessionInfo?
    @Published var pairing: PairingInfo?
    @Published var pendingRequest: PendingRequest?
    @Published var pairingOutcome: String?
    @Published var lastMessage = ""
    @Published var screenRecording = Permissions.screenRecordingGranted
    @Published var accessibility = Permissions.accessibilityGranted
    @Published var hostNameSetting: String
    @Published var idleTimeoutMinutes: Int

    let agent: Agent
    let config: AgentConfig
    private var control: LocalControlServer?
    private var eventsTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    static let defaults = UserDefaults.standard

    var fingerprint: String { agent.identity.fingerprint }
    var menuIcon: String {
        if session?.path != nil { return "display.and.arrow.down" }
        if !remoteAccess { return "display.trianglebadge.exclamationmark" }
        return "display"
    }

    init() {
        var config = AgentConfig.standard()
        if let name = Self.defaults.string(forKey: "hostName"), !name.isEmpty { config.hostName = name }
        let idle = Self.defaults.integer(forKey: "idleTimeoutMinutes")
        if idle > 0 { config.idleTimeout = TimeInterval(idle * 60) }
        if let url = Self.defaults.string(forKey: "rendezvousURL"), !url.isEmpty { config.rendezvousURL = url }
        var args = Array(CommandLine.arguments.dropFirst())
        var useFileIdentity = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--data-dir": if !args.isEmpty { config.dataDirectory = URL(fileURLWithPath: args.removeFirst(), isDirectory: true) }
            case "--file-identity": useFileIdentity = true
            case "--synthetic-screen": config.syntheticScreen = true
            case "--no-input": config.inputEnabled = false
            default: break
            }
        }
        if useFileIdentity { config.identityFile = config.dataDirectory.appendingPathComponent("identity.key") }
        self.config = config
        hostNameSetting = config.hostName
        idleTimeoutMinutes = Int(config.idleTimeout / 60)
        do {
            // Ad-hoc builds keep the (Secure Enclave backed) identity in the data folder rather than the
            // Keychain, because each rebuild changes the signature and would trigger a Keychain prompt.
            let identity: (any SigningIdentity)? = config.identityFile == nil && CodeSigning.isAdHocSigned
                ? try FileBackedIdentityStore.loadOrCreate(at: config.dataDirectory.appendingPathComponent("identity.json"))
                : nil
            agent = try Agent(config: config, identity: identity)
        } catch {
            let alert = NSAlert()
            alert.messageText = "PRC Agent cannot start"
            alert.informativeText = "\(error)"
            alert.runModal()
            exit(1)
        }
        devices = agent.trust.all
        remoteAccess = Self.defaults.object(forKey: "remoteAccessOnLaunch") as? Bool ?? true

        let stream = agent.events
        eventsTask = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        do {
            if remoteAccess { try agent.start() } else { Task { try? await agent.setRemoteAccess(false) } }
        } catch {
            lastMessage = "Could not start listening: \(error)"
        }

        // Ask only for what this configuration will actually use, so test runs never prompt.
        if config.mediaEnabled, !config.syntheticScreen, !screenRecording { Permissions.requestScreenRecording() }
        if config.inputEnabled, !accessibility { Permissions.requestAccessibility() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.screenRecording = Permissions.screenRecordingGranted
                self?.accessibility = Permissions.accessibilityGranted
            }
        }
        if notificationsAvailable {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        let server = LocalControlServer(controlFile: config.dataDirectory.appendingPathComponent("control.json")) { [weak self] request in
            guard let self else { return .failure("app is shutting down") }
            return await self.handleControl(request)
        }
        try? server.start()
        control = server
    }

    // MARK: Local control (prc-agent ctl …)

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
            "remote_access": remoteAccess ? "on" : "off",
            "port": String(port),
            "addresses": addresses.joined(separator: ","),
            "fingerprint": fingerprint,
            "device_id": agent.identity.deviceId,
            "devices": String(devices.count),
            "screen_recording": screenRecording ? "granted" : "missing",
            "accessibility": accessibility ? "granted" : "missing",
        ]
        if let s = session { d["session_device"] = s.deviceName; d["session_phase"] = s.phase; d["session_path"] = s.path ?? "" }
        if let p = pendingRequest { d["pending_name"] = p.name; d["pending_fingerprint"] = p.fingerprint }
        if pairing != nil { d["pairing"] = "open" }
        return d
    }

    func handleControl(_ request: ControlRequest) async -> ControlResponse {
        switch request.command {
        case "status":
            let s = session.map { "\($0.deviceName): \($0.path ?? $0.phase)" } ?? "no session"
            return ControlResponse(ok: true, message: "remote access \(remoteAccess ? "on" : "off"), \(s), \(devices.count) trusted device(s)", data: statusData)
        case "pair":
            guard remoteAccess else { return .failure("remote access is off") }
            startPairing()
            guard await waitUntil(3000, { pairing != nil }), let pairing else { return .failure("pairing did not open") }
            return ControlResponse(ok: true, message: pairing.payloadText, data: ["fingerprint": fingerprint, "expires_at": String(Int(pairing.expiresAt.timeIntervalSince1970 * 1000))])
        case "pending":
            guard await waitUntil(Int(request.args.first ?? "") ?? 120_000, { pendingRequest != nil || pairing == nil }), let p = pendingRequest else {
                return .failure(pairing == nil ? "pairing window closed" : "no request yet")
            }
            return ControlResponse(ok: true, message: "\(p.name) (\(p.type.rawValue)) fingerprint \(p.fingerprint)", data: ["name": p.name, "type": p.type.rawValue, "fingerprint": p.fingerprint, "device_id": p.deviceId])
        case "approve", "deny":
            guard pendingRequest != nil else { return .failure("no pending pairing request") }
            pairingOutcome = nil
            if request.command == "approve" { approvePairing() } else { denyPairing() }
            _ = await waitUntil(5000, { pairingOutcome != nil })
            return ControlResponse(ok: pairingOutcome?.hasPrefix("Paired") == true || request.command == "deny", message: pairingOutcome ?? "no outcome", data: statusData)
        case "cancel":
            cancelPairing()
            return ControlResponse(ok: true, message: "pairing cancelled")
        case "devices":
            let lines = devices.map { "\($0.fingerprint)  \($0.name) (\($0.type.rawValue))  \($0.deviceId)" }
            return ControlResponse(ok: true, message: lines.isEmpty ? "none" : lines.joined(separator: "\n"), data: ["count": String(devices.count)])
        case "revoke":
            guard let prefix = request.args.first else { return .failure("revoke needs a device id or fingerprint prefix") }
            let matches = devices.filter { $0.deviceId.hasPrefix(prefix.lowercased()) || $0.fingerprint.hasPrefix(prefix.uppercased()) }
            guard matches.count == 1 else { return .failure("\(matches.count) devices match") }
            revoke(matches[0].deviceId)
            _ = await waitUntil(3000, { !devices.contains { $0.deviceId == matches[0].deviceId } })
            return ControlResponse(ok: true, message: "revoked \(matches[0].name)")
        case "end":
            endSession()
            _ = await waitUntil(5000, { session == nil })
            return ControlResponse(ok: session == nil, message: session == nil ? "session ended" : "session still active")
        case "access":
            guard let arg = request.args.first, ["on", "off"].contains(arg) else { return .failure("access needs on or off") }
            setRemoteAccess(arg == "on")
            _ = await waitUntil(3000, { remoteAccess == (arg == "on") })
            return ControlResponse(ok: true, message: "remote access \(remoteAccess ? "on" : "off")")
        case "quit":
            Task { quit() }
            return ControlResponse(ok: true, message: "quitting")
        default:
            return .failure("unknown command \(request.command)")
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .listening(let port, let addresses):
            self.port = port
            self.addresses = addresses
        case .pairingOpened(let qr):
            let data = (try? JSONEncoder().encode(qr)) ?? Data()
            pairing = PairingInfo(qr: qr, payloadText: String(decoding: data, as: UTF8.self), image: Self.qrImage(data), expiresAt: Date(timeIntervalSince1970: Double(qr.expires_at) / 1000))
            pendingRequest = nil
            pairingOutcome = nil
        case .pairingRequest(let deviceId, let name, let type, let fingerprint):
            pendingRequest = PendingRequest(deviceId: deviceId, name: name, type: type, fingerprint: fingerprint)
            NSApp.activate(ignoringOtherApps: true)
            notify("Pairing request", "\(name) wants to pair. Compare fingerprints, then approve or deny.")
        case .pairingCompleted(_, let name):
            devices = agent.trust.all
            pairingOutcome = "Paired with \(name)."
            pendingRequest = nil
        case .pairingFailed(let reason):
            pairingOutcome = "Pairing not completed: \(reason)."
            pendingRequest = nil
        case .pairingClosed:
            pairing = nil
            pendingRequest = nil
        case .sessionRequested(_, let name):
            session = SessionInfo(deviceName: name, phase: "authenticating", path: nil, since: Date())
        case .sessionAuthenticated(_, let name):
            session = SessionInfo(deviceName: name, phase: "negotiating", path: nil, since: session?.since ?? Date())
            devices = agent.trust.all
        case .sessionConnected(let name, let path):
            session = SessionInfo(deviceName: name, phase: "connected", path: path, since: session?.since ?? Date())
            notify("Remote session started", "\(name) is controlling this Mac (\(path)).")
        case .sessionEnded(let reason):
            if let s = session { notify("Remote session ended", "\(s.deviceName): \(reason.rawValue)") }
            session = nil
        case .rejected(let deviceId, let reason):
            lastMessage = "Rejected \(String(deviceId.prefix(12)))…: \(reason.rawValue)"
        case .remoteAccessChanged(let on):
            remoteAccess = on
            if !on { session = nil }
        case .deviceRevoked:
            devices = agent.trust.all
        case .warning(let text):
            lastMessage = text
        case .info(let text):
            lastMessage = text
        }
    }

    // MARK: Actions

    func setRemoteAccess(_ on: Bool) {
        Self.defaults.set(on, forKey: "remoteAccessOnLaunch")
        Task {
            do { try await agent.setRemoteAccess(on) } catch { lastMessage = "\(error)" }
        }
    }

    func startPairing() {
        guard pairing == nil else { return }
        Task { _ = await agent.coordinator.openPairing() }
    }

    func cancelPairing() {
        Task { await agent.coordinator.cancelPairing() }
    }

    func approvePairing() {
        Task { await agent.coordinator.resolvePairing(approved: true) }
    }

    func denyPairing() {
        Task { await agent.coordinator.resolvePairing(approved: false) }
    }

    func revoke(_ deviceId: String) {
        Task { await agent.coordinator.revoke(deviceId: deviceId) }
    }

    func endSession() {
        Task { await agent.coordinator.endSession(reason: .user) }
    }

    func saveSettings() {
        Self.defaults.set(hostNameSetting, forKey: "hostName")
        Self.defaults.set(idleTimeoutMinutes, forKey: "idleTimeoutMinutes")
        lastMessage = "Settings apply after relaunch."
    }

    func copyPayload() {
        guard let pairing else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairing.payloadText, forType: .string)
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func quit() {
        Task {
            await agent.stop()
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
