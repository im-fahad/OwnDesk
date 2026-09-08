import Foundation
import PRCAgentCore
import PRCControllerCore
import PRCIdentity
import PRCPeers

/// One app, one identity, one folder. The two halves of PRC used to keep their own of each, which
/// made a single Mac look like two devices to everyone else.
struct AppConfiguration {
    var dataDirectory: URL
    var deviceName: String
    /// Development only: keep the identity in the data folder rather than the Keychain.
    var useFileIdentity = false
    /// Start without opening the control window, for the copy launchd starts at login.
    var background = false
    /// Test only.
    var syntheticScreen = false
    var hostingEnabled: Bool
    var port: UInt16 = AgentConfig.defaultPort

    static let hostingDefaultsKey = "hostingEnabled"

    static func fromCommandLine(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> AppConfiguration {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        var config = AppConfiguration(
            dataDirectory: support.appendingPathComponent("PRC", isDirectory: true),
            deviceName: Host.current().localizedName ?? "Mac",
            // Hosting stays off until asked for. Installing this app should not quietly make a
            // laptop remotely controllable.
            hostingEnabled: UserDefaults.standard.bool(forKey: hostingDefaultsKey)
        )
        var args = arguments
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--data-dir": if !args.isEmpty { config.dataDirectory = URL(fileURLWithPath: args.removeFirst(), isDirectory: true) }
            case "--name": if !args.isEmpty { config.deviceName = args.removeFirst() }
            case "--port": if !args.isEmpty { config.port = UInt16(args.removeFirst()) ?? config.port }
            case "--file-identity": config.useFileIdentity = true
            case "--background": config.background = true
            case "--synthetic-screen": config.syntheticScreen = true
            case "--host": config.hostingEnabled = true
            default: break
            }
        }
        return config
    }

    /// Where the split apps kept their data, for a one-time import.
    var legacyAgentDirectory: URL { dataDirectory }
    var legacyControllerDirectory: URL {
        dataDirectory.deletingLastPathComponent().appendingPathComponent("PRC Controller", isDirectory: true)
    }

    var identityFile: URL { dataDirectory.appendingPathComponent("identity.json") }

    /// The agent half's settings. Hosting is started and stopped at runtime, not by this flag.
    func agentConfig() -> AgentConfig {
        var agent = AgentConfig(
            hostName: deviceName,
            port: port,
            dataDirectory: dataDirectory,
            syntheticScreen: syntheticScreen
        )
        if useFileIdentity { agent.identityFile = identityFile }
        return agent
    }

    func controllerConfig() -> ControllerConfig {
        var controller = ControllerConfig(deviceName: deviceName, dataDirectory: dataDirectory)
        if useFileIdentity { controller.identityFile = identityFile }
        return controller
    }

    /// Loads the one identity this Mac uses in both roles, bringing forward whichever the split apps
    /// left behind so existing pairings keep working.
    func loadIdentity() throws -> any SigningIdentity {
        let file = identityFile
        if !FileManager.default.fileExists(atPath: file.path) {
            for legacy in [legacyControllerDirectory.appendingPathComponent("identity.json"),
                           legacyAgentDirectory.appendingPathComponent("identity.json")]
            where FileManager.default.fileExists(atPath: legacy.path) && legacy != file {
                try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? FileManager.default.copyItem(at: legacy, to: file)
                break
            }
        }
        if useFileIdentity || CodeSigning.isAdHocSigned || FileManager.default.fileExists(atPath: file.path) {
            return try FileBackedIdentityStore.loadOrCreate(at: file)
        }
        return try IdentityStore.loadOrCreate(service: "prc.identity")
    }
}
