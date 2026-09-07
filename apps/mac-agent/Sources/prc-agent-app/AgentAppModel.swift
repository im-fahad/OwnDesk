import AppKit
import Combine
import CoreImage
import Foundation
import PRCAgentCore
import PRCIdentity
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
            agent = try Agent(config: config)
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
