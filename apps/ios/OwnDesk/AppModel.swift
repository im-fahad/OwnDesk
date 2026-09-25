import Foundation
import Network
import OSLog
import OwnDeskControllerCore
import OwnDeskIdentity
import OwnDeskPeers
import OwnDeskProtocol
import UIKit

/// A Mac to open, and the addresses to try for it.
struct SessionTarget: Identifiable, Equatable {
    let peer: Peer
    let addresses: [String]
    var id: String { peer.deviceId }
}

/// Something to tell the person once a screen has closed.
struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Everything the home screen shows, and the actions behind it: this iPhone's identity, the Macs it
/// is paired with, where each one can be reached, pairing and unpairing.
@MainActor @Observable
final class AppModel {
    static let logger = Logger(subsystem: "owndesk.ios", category: "app")
    /// "iPhone" or "iPad", for sentences that name this device.
    static let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

    @ObservationIgnored let identity: any SigningIdentity
    @ObservationIgnored let config: ControllerConfig
    @ObservationIgnored private let peers: PeerStore
    @ObservationIgnored private let discovery: HostDiscovery
    @ObservationIgnored private var browsing = false
    @ObservationIgnored private var resolvedEndpoints: [String: String] = [:]
    @ObservationIgnored private var probeGeneration = 0
    @ObservationIgnored private var started = false

    /// The paired Macs, oldest pairing first.
    private(set) var macs: [Peer] = []
    /// Macs heard advertising themselves on this network right now, by device id.
    private(set) var onThisNetwork: [String: String] = [:]
    /// Macs whose address answered the last probe.
    private(set) var reachable: Set<String> = []
    /// An address the person pinned for a Mac, by device id. Tried first, before anything else.
    private(set) var pins: [String: String] = [:]
    private(set) var log: [String] = []
    private(set) var status = ""
    /// The Mac a pairing attempt is waiting on, while one is.
    private(set) var pairingWith: String?
    var activeSession: SessionTarget?
    var notice: Notice?

    private static let pinsKey = "addressPins"

    init() {
        let directory = Self.dataDirectory()
        #if DEBUG
        // A clean start for tests, from a launch argument: -OwnDeskReset YES.
        if UserDefaults.standard.bool(forKey: "OwnDeskReset") {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removeObject(forKey: Self.pinsKey)
        }
        #endif
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)

        var startup: [String] = []
        identity = Self.loadIdentity(at: directory.appendingPathComponent("identity.json"), notes: &startup)
        peers = Self.loadPeers(in: directory, notes: &startup)
        config = ControllerConfig(deviceName: UIDevice.current.name, dataDirectory: directory,
                                  app: .iosController, appVersion: Self.appVersion)
        discovery = HostDiscovery(serviceType: config.serviceType)
        pins = UserDefaults.standard.dictionary(forKey: Self.pinsKey) as? [String: String] ?? [:]
        macs = peers.hosts

        discovery.onUpdate = { [weak self] hosts in
            Task { @MainActor in self?.found(hosts) }
        }
        note("this \(Self.deviceKind) is \(identity.fingerprint)")
        startup.forEach(note)
    }

    // MARK: Lifecycle

    /// Once, when the home screen first appears.
    func start() {
        guard !started else { return }
        started = true
        becameActive()
        #if DEBUG
        runLaunchCommands()
        #endif
    }

    func becameActive() {
        if !browsing {
            browsing = true
            discovery.start()
        }
        refresh()
    }

    func wentToBackground() {
        guard browsing else { return }
        browsing = false
        discovery.stop()
        resolvedEndpoints.removeAll()
    }

    /// Re-reads the paired Macs and checks which of them answer.
    func refresh() {
        macs = peers.hosts
        probe()
    }

    // MARK: Addresses

    /// Every address worth trying for a Mac: a pinned one first, then where it was just heard on this
    /// network, then the ones it has answered on or advertised. All of them are probed at once when
    /// connecting, so the order only breaks ties.
    func candidates(for peer: Peer) -> [String] {
        var seen = Set<String>()
        let all = [pins[peer.deviceId], onThisNetwork[peer.deviceId]].compactMap { $0 } + peer.addresses
        return all
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Pins an address for a Mac, or clears the pin when the text is blank.
    func setPin(_ address: String?, for peer: Peer) {
        let clean = address?.trimmingCharacters(in: .whitespaces) ?? ""
        pins[peer.deviceId] = clean.isEmpty ? nil : clean
        UserDefaults.standard.set(pins, forKey: Self.pinsKey)
        note(clean.isEmpty ? "\(peer.name) will use whichever address answers" : "\(peer.name) will use \(clean)")
        probe()
    }

    /// What an address is for, since the choice between them is really a choice of route.
    func note(for address: String, of peer: Peer) -> String {
        if address == onThisNetwork[peer.deviceId] { return "on this network now" }
        let host = Endpoints.url(for: address)?.host ?? address
        if PathClassifier.isOverlay(host) { return "Tailscale, reaches it from anywhere" }
        if PathClassifier.isPrivate(host) || host.hasSuffix(".local") { return "local network" }
        return "elsewhere"
    }

    private func found(_ hosts: [HostDiscovery.DiscoveredHost]) {
        for host in hosts where peers.peer(host.deviceId) != nil {
            let described = Endpoints.describe(host.endpoint)
            guard resolvedEndpoints[host.deviceId] != described else { continue }
            resolvedEndpoints[host.deviceId] = described
            Task {
                guard let url = await Endpoints.resolve(host.endpoint), let address = Self.address(of: url),
                      onThisNetwork[host.deviceId] != address else { return }
                onThisNetwork[host.deviceId] = address
                note("\(peers.peer(host.deviceId)?.name ?? "a Mac") is on this network at \(address)")
                probe()
            }
        }
    }

    /// Green dots. A plain TCP connect to each Mac's addresses, which proves a port is open rather
    /// than that the right Mac is behind it; connecting is what checks that.
    private func probe() {
        probeGeneration += 1
        let generation = probeGeneration
        for mac in macs {
            let urls = candidates(for: mac).compactMap(Endpoints.url(for:))
            Task {
                let answered = await Endpoints.firstReachable(urls, timeoutMs: 1200) != nil
                guard generation == probeGeneration else { return }
                if answered { reachable.insert(mac.deviceId) } else { reachable.remove(mac.deviceId) }
            }
        }
    }

    // MARK: Pairing

    func pair(code: String) {
        guard pairingWith == nil else { return }
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { note("nothing pasted"); return }
        let qr: QRPayload
        do { qr = try PairingClient.parse(text) } catch {
            note("pairing failed: \(Self.describe(error))")
            notice = Notice(title: "Not a pairing code", message: "Copy or scan the code a Mac shows under Pair a Mac… → Show a code.")
            return
        }
        pairingWith = qr.host_name
        note("code is from \(qr.host_name), \((try? DeviceID.fingerprint(deviceId: qr.host_device_id)) ?? "?")")
        note("approve on the Mac if it shows \(identity.fingerprint)")

        let client = PairingClient(identity: identity, deviceName: config.deviceName, deviceType: .ios)
        Task {
            defer { pairingWith = nil }
            do {
                let outcome = try await client.pair(qr: qr)
                let host = outcome.host
                // A phone only ever controls: the Mac never opens a session to it.
                try peers.pair(deviceId: host.deviceId, publicKey: host.publicKey, name: host.name, type: .mac,
                               mayControlUs: false, weMayControl: true, addresses: [outcome.address] + host.addresses,
                               rendezvousURL: host.rendezvousURL, now: nowMs())
                note("paired with \(host.name) on \(outcome.address)")
                refresh()
            } catch {
                note("pairing failed: \(Self.describe(error))")
                notice = Notice(title: "Pairing did not finish", message: Self.describe(error).capitalizedFirst + ".")
            }
        }
    }

    // MARK: Sessions

    func connect(_ peer: Peer) {
        guard activeSession == nil else { return }
        let addresses = candidates(for: peer)
        guard !addresses.isEmpty else {
            notice = Notice(title: "No address for \(peer.name)", message: "Touch and hold it, choose an address, and try again.")
            return
        }
        note("opening \(peer.name)")
        activeSession = SessionTarget(peer: peer, addresses: addresses)
    }

    /// Worth remembering: next time this address is tried with the others, from the front.
    func sessionConnected(_ target: SessionTarget, address: String) {
        peers.touchConnected(target.peer.deviceId, at: nowMs(), address: address)
        reachable.insert(target.peer.deviceId)
    }

    func sessionEnded(_ target: SessionTarget, reason: String) {
        if activeSession?.id == target.id { activeSession = nil }
        note("\(target.peer.name): \(reason)")
        let name = target.peer.name
        if reason == "rejected: \(SessionRejectReason.untrusted.rawValue)" {
            // The Mac answered, with its own signature, that it no longer has this device paired, so
            // the pairing is dropped here too and both sides must pair again.
            forgetHere(target.peer)
            notice = Notice(title: "\(name) was removed",
                            message: "\(name) no longer has this \(Self.deviceKind) paired, so it was removed here too. Pair again to use it.")
        } else if let text = Self.explainEnd(reason, peer: name) {
            notice = Notice(title: "Session with \(name) ended", message: text)
        }
        refresh()
    }

    // MARK: Unpairing

    /// Removes the pairing on both sides. The Mac is told with a signed UNPAIR when it can be
    /// reached; when it cannot, it still lists this device, and the person is asked to unpair there.
    func unpair(_ peer: Peer) {
        let urls = candidates(for: peer).compactMap(Endpoints.url(for:))
        forgetHere(peer)
        Task {
            if await UnpairClient.send(to: peer.deviceId, urls: urls, identity: identity) {
                note("unpaired \(peer.name) on both sides")
            } else {
                note("unpaired \(peer.name) here, but it could not be reached")
                notice = Notice(title: "\(peer.name) was not told",
                                message: "It could not be reached, so it still lists this \(Self.deviceKind). Unpair this \(Self.deviceKind) on the Mac too.")
            }
        }
    }

    private func forgetHere(_ peer: Peer) {
        _ = try? peers.forget(peer.deviceId)
        onThisNetwork[peer.deviceId] = nil
        resolvedEndpoints[peer.deviceId] = nil
        reachable.remove(peer.deviceId)
        if pins.removeValue(forKey: peer.deviceId) != nil {
            UserDefaults.standard.set(pins, forKey: Self.pinsKey)
        }
        macs = peers.hosts
    }

    // MARK: Log

    func note(_ line: String) {
        let stamp = Self.clock.string(from: Date())
        log.append("\(stamp)  \(line)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
        status = line
        // Mirrored so a build under test can be watched from a computer:
        //   xcrun simctl spawn booted log stream --predicate 'subsystem == "owndesk.ios"'
        Self.logger.notice("\(line, privacy: .public)")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: Words

    /// Why a session ended, in words that say what to do about it, or nil when there is nothing to
    /// say because the person ended it. The same wording as the Mac app's, for a phone.
    static func explainEnd(_ reason: String, peer name: String) -> String? {
        let device = deviceKind
        switch reason {
        case "disconnected":
            return nil
        case "rejected: \(SessionRejectReason.revoked.rawValue)":
            return "\(name) has turned off control for this \(device). On \(name), right-click this \(device) in the sidebar and switch on “Allow it to control this Mac”."
        case "rejected: \(SessionRejectReason.remoteAccessDisabled.rawValue)":
            return "\(name) is not letting others control it. On \(name), switch on “Let others control it”."
        case "rejected: \(SessionRejectReason.busy.rawValue)":
            return "\(name) is already being controlled by another device. End that session first."
        case "no address":
            return "Could not reach \(name). It may be asleep or offline, or “Let others control it” may be off on it. Away from home, both need Tailscale."
        default:
            return reason.hasPrefix("host ended the session") ? "\(name) ended the session." : reason.capitalizedFirst + "."
        }
    }

    static func describe(_ error: Error) -> String {
        guard let pairing = error as? PairingError else { return error.localizedDescription }
        switch pairing {
        case .invalidPayload: return "that is not an OwnDesk pairing code"
        case .expired: return "the code has expired; show a new one on the Mac"
        case .noReachableAddress, .connection:
            return "could not reach the Mac at any address in the code; pairing needs both on the same network"
        case .hostKeyMismatch: return "the Mac that answered is not the one that showed the code"
        case .refused(let reason):
            switch reason {
            case .expired?: return "the Mac's pairing window closed; show a new code"
            case .busy?: return "the Mac is already pairing with another device"
            case .badProof?: return "the code did not match; show a new one"
            default: return "the Mac said no"
            }
        case .timeout: return "the Mac did not answer in time; approve it there within two minutes"
        }
    }

    // MARK: Storage

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.2.0"
    }

    static func dataDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OwnDesk", isDirectory: true)
    }

    /// Kept out of backups: the identity is a Secure Enclave key that only this device can use, so a
    /// copy restored anywhere else, or onto this device after an erase, could never sign again.
    private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func loadIdentity(at file: URL, notes: inout [String]) -> any SigningIdentity {
        if let identity = try? FileBackedIdentityStore.loadOrCreate(at: file) { return identity }
        // A key this device cannot use: start again with a new one, which every Mac will see as a
        // stranger until it is paired again.
        try? FileManager.default.removeItem(at: file)
        if let identity = try? FileBackedIdentityStore.loadOrCreate(at: file) {
            notes.append("the stored key could not be used, so this \(deviceKind) has a new one; pair again with each Mac")
            return identity
        }
        notes.append("could not store a key; this identity lasts only until the app closes")
        return SoftwareIdentity()
    }

    private static func loadPeers(in directory: URL, notes: inout [String]) -> PeerStore {
        if let store = try? PeerStore(directory: directory) { return store }
        let file = directory.appendingPathComponent("peers.json")
        try? FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("peers.unreadable.json"))
        notes.append("the list of paired Macs could not be read and was set aside; pair again")
        if let store = try? PeerStore(directory: directory) { return store }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-peers", isDirectory: true)
        return try! PeerStore(directory: scratch)
    }

    /// "host:port", or "[v6]:port", the form addresses are stored and shown in.
    static func address(of url: URL) -> String? {
        guard let host = url.host, let port = url.port else { return nil }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    // MARK: Test hooks

    #if DEBUG
    /// Lets a debug build be driven from a computer, the way the Android debug build takes intent
    /// extras, so pairing and connecting can be tested in the Simulator without typing. Launch
    /// arguments, for example `xcrun simctl launch booted <bundle id> -OwnDeskConnect 25AA`:
    ///   -OwnDeskPairCode <base64url of the pairing code text>   pair with it
    ///   -OwnDeskConnect <fingerprint or device id prefix>       open that Mac
    ///   -OwnDeskAddress <host:port>                             pin that address first
    ///   -OwnDeskReset YES                                       forget everything first
    /// A release build ignores them all.
    private func runLaunchCommands() {
        let defaults = UserDefaults.standard
        if let encoded = defaults.string(forKey: "OwnDeskPairCode"),
           let data = Base64URL.decode(encoded), let text = String(data: data, encoding: .utf8) {
            pair(code: text)
        }
        if let prefix = defaults.string(forKey: "OwnDeskConnect") {
            guard let match = macs.first(where: {
                $0.fingerprint.replacingOccurrences(of: "-", with: "").hasPrefix(prefix.uppercased().replacingOccurrences(of: "-", with: ""))
                    || $0.deviceId.hasPrefix(prefix.lowercased())
            }) else {
                note("no paired Mac matches \(prefix)")
                return
            }
            if let address = defaults.string(forKey: "OwnDeskAddress") { setPin(address, for: match) }
            connect(match)
        }
    }
    #endif
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
