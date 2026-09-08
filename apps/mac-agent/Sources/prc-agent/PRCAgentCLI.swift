import Foundation
import PRCAgentCore
import PRCLocalControl
import PRCProtocol

/// Headless development runner for the agent. The menu bar app arrives in a later step; until then this
/// prints events and takes pairing approvals and commands on stdin.
@main
enum PRCAgentCLI {
    static let usage = """
    prc-agent [options]                run the headless agent
    prc-agent ctl <command> [args]     talk to the running PRC Agent menu bar app

    ctl commands: status | pair | pending [timeout ms] | approve | deny | cancel | devices |
                  revoke <prefix> | end | access on|off | quit

      --name <text>       Host name shown to controllers (default: this Mac's name)
      --port <n>          Signaling port (default 47500, 0 = ephemeral)
      --data-dir <path>   Where trusted devices are stored
      --no-media          Signaling and sessions only, no capture or WebRTC
      --no-input          Never inject input, just validate it
      --no-bonjour        Do not advertise on the LAN
      --file-identity     DEV ONLY: keep the identity in <data-dir>/identity.json instead of the Keychain
      --synthetic-screen  TEST ONLY: stream a generated pattern instead of the screen (no Screen Recording needed)
      --help

    Commands while running:
      pair                Open a 120 s pairing window and print the QR payload text
      cancel              Close the pairing window
      y | n               Approve or deny the pending pairing request
      devices             List trusted devices
      revoke <prefix>     Revoke a trusted device by device id prefix
      access on|off       Remote Access kill switch
      end                 End the active session
      status              Show permissions and state
      quit
    """

    static func main() async throws {
        // Line-buffer stdout so a parent process (the headless test, a UI wrapper) sees events as they happen.
        setlinebuf(stdout)
        if CommandLine.arguments.dropFirst().first == "ctl" {
            await control(Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        var config = AgentConfig.standard()
        var useFileIdentity = false
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--name": config.hostName = args.isEmpty ? config.hostName : args.removeFirst()
            case "--port": config.port = UInt16(args.isEmpty ? "" : args.removeFirst()) ?? config.port
            case "--data-dir": if !args.isEmpty { config.dataDirectory = URL(fileURLWithPath: args.removeFirst(), isDirectory: true) }
            case "--no-media": config.mediaEnabled = false
            case "--no-input": config.inputEnabled = false
            case "--no-bonjour": config.advertiseBonjour = false
            case "--file-identity": useFileIdentity = true
            case "--synthetic-screen": config.syntheticScreen = true
            case "--help", "-h": print(usage); return
            default: print("unknown option \(arg)\n\(usage)"); exit(2)
            }
        }

        // Resolved after parsing so --data-dir applies regardless of flag order.
        if useFileIdentity { config.identityFile = config.dataDirectory.appendingPathComponent("identity.json") }

        let agent = try Agent(config: config)
        print("PRC agent")
        print("  host name    \(config.hostName)")
        print("  device id    \(agent.identity.deviceId)")
        print("  fingerprint  \(agent.identity.fingerprint)")
        print("  data dir     \(config.dataDirectory.path)")
        print("  media        \(config.mediaEnabled ? "on" : "off")   input \(config.inputEnabled ? "on" : "off")   bonjour \(config.advertiseBonjour ? "on" : "off")")
        print("  identity     \(config.identityFile == nil ? "Keychain / Secure Enclave" : "DEV FILE \(config.identityFile!.path)")")
        printPermissions(config)
        if config.syntheticScreen { print("  screen        SYNTHETIC PATTERN (test only)") }
        if config.mediaEnabled, !config.syntheticScreen, !Permissions.screenRecordingGranted {
            print("  requesting Screen Recording permission (grant it in System Settings > Privacy & Security, then restart)")
            Permissions.requestScreenRecording()
        }
        if config.inputEnabled, !Permissions.accessibilityGranted {
            print("  requesting Accessibility permission (grant it in System Settings > Privacy & Security)")
            Permissions.requestAccessibility()
        }

        let eventTask = Task {
            for await event in agent.events { printEvent(event) }
        }
        try agent.start()
        print("type 'help' for commands\n")

        let stdinTask = Task.detached {
            while let line = readLine() {
                let parts = line.split(separator: " ").map(String.init)
                guard let command = parts.first else { continue }
                switch command {
                case "help": print(usage)
                case "pair":
                    let qr = await agent.coordinator.openPairing()
                    if let data = try? JSONEncoder().encode(qr), let text = String(data: data, encoding: .utf8) {
                        print("pairing open for 120 s. Paste this into the controller:\n\(text)\n")
                    }
                case "cancel": await agent.coordinator.cancelPairing()
                case "y", "yes": await agent.coordinator.resolvePairing(approved: true)
                case "n", "no": await agent.coordinator.resolvePairing(approved: false)
                case "devices":
                    let devices = await agent.coordinator.trustedDevices
                    if devices.isEmpty { print("no trusted devices") }
                    for d in devices {
                        let seen = d.lastSeen.map { Date(timeIntervalSince1970: Double($0) / 1000).description } ?? "never"
                        print("  \(d.fingerprint)  \(d.name) (\(d.type.rawValue))  id \(d.deviceId.prefix(16))…  last seen \(seen)")
                    }
                case "revoke":
                    guard parts.count > 1 else { print("usage: revoke <device id prefix>"); continue }
                    let matches = await agent.coordinator.trustedDevices.filter { $0.deviceId.hasPrefix(parts[1]) }
                    if matches.count == 1 { await agent.coordinator.revoke(deviceId: matches[0].deviceId) } else { print("\(matches.count) devices match; be more specific") }
                case "access":
                    guard parts.count > 1, ["on", "off"].contains(parts[1]) else { print("usage: access on|off"); continue }
                    try? await agent.setRemoteAccess(parts[1] == "on")
                case "end": await agent.coordinator.endSession(reason: .user)
                case "status":
                    printPermissions(config)
                    print("  remote access \(await agent.coordinator.remoteAccessEnabled ? "on" : "off"), session \(await agent.coordinator.hasActiveSession ? "active" : "none"), port \(agent.port)")
                case "quit", "exit":
                    await agent.stop()
                    exit(0)
                default: print("unknown command; type 'help'")
                }
            }
        }

        _ = await stdinTask.value
        eventTask.cancel()
        await agent.stop()
    }

    /// `prc-agent ctl …`: drives the running menu bar app through its local control channel.
    static func control(_ argsIn: [String]) async {
        var args = argsIn
        var dataDir = AgentConfig.standard().dataDirectory
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            dataDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            args.removeSubrange(i...(i + 1))
        }
        guard let command = args.first else { print(usage); exit(2) }
        do {
            let response = try await LocalControlClient.send(ControlRequest(command: command, args: Array(args.dropFirst())), controlFile: dataDir.appendingPathComponent("control.json"))
            print(response.message)
            for key in response.data.keys.sorted() { print("  \(key): \(response.data[key]!)") }
            exit(response.ok ? 0 : 1)
        } catch LocalControlError.notRunning {
            print("PRC Agent is not running (no control.json in \(dataDir.path))")
            exit(3)
        } catch {
            print("control error: \(error)")
            exit(3)
        }
    }

    static func printPermissions(_ config: AgentConfig) {
        print("  screen recording \(Permissions.screenRecordingGranted ? "granted" : "NOT granted")   accessibility \(Permissions.accessibilityGranted ? "granted" : "NOT granted")")
    }

    static func printEvent(_ event: AgentEvent) {
        switch event {
        case .listening(let port, let addresses):
            print("listening on port \(port): \(addresses.joined(separator: ", "))")
        case .pairingOpened(let qr):
            print("pairing window open until \(Date(timeIntervalSince1970: Double(qr.expires_at) / 1000))")
        case .pairingRequest(_, let name, let type, let fingerprint):
            print("\nPAIRING REQUEST from \"\(name)\" (\(type.rawValue))\n  controller fingerprint: \(fingerprint)\n  compare with the fingerprint shown on that device, then type y or n\n")
        case .pairingCompleted(_, let name):
            print("paired \"\(name)\"")
        case .pairingFailed(let reason):
            print("pairing: \(reason)")
        case .pairingClosed:
            print("pairing window closed")
        case .sessionRequested(_, let name):
            print("session requested by \"\(name)\", challenge sent")
        case .sessionAuthenticated(_, let name):
            print("\"\(name)\" authenticated, waiting for WebRTC offer")
        case .sessionConnected(let name, let path):
            print("\"\(name)\" connected: \(path)")
        case .sessionEnded(let reason):
            print("session ended: \(reason.rawValue)")
        case .rejected(let deviceId, let reason):
            print("rejected \(deviceId.prefix(12))…: \(reason.rawValue)")
        case .remoteAccessChanged(let on):
            print("remote access \(on ? "ON" : "OFF")")
        case .deviceRevoked(let deviceId):
            print("revoked \(deviceId.prefix(12))…")
        case .warning(let text):
            print("warning: \(text)")
        case .info(let text):
            print(text)
        }
    }
}
