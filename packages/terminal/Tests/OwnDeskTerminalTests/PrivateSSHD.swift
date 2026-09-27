import Foundation

/// A throwaway OpenSSH server for tests: the Mac's own `/usr/sbin/sshd`, run as this user on a free
/// port, with its own host key and its own list of authorized keys in a temporary folder. It needs
/// no permission and leaves the Mac's Remote Login setting alone. As a user process it can only log
/// in as that user, which is all a test needs.
final class PrivateSSHD {
    let port: Int
    let folder: URL
    let hostPublicKey: String
    private let process: Process

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") }

    /// `passwords` makes it offer password login too. It can never succeed, since a server not
    /// running as root cannot check a password, which is enough to test the offer and the refusal.
    init(authorizedKeys: [String], passwords: Bool = false) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("owndesk-sshd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hostKey = folder.appendingPathComponent("host_key")
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        hostPublicKey = try String(contentsOf: hostKey.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authorized = folder.appendingPathComponent("authorized_keys")
        try (authorizedKeys.joined(separator: "\n") + "\n").write(to: authorized, atomically: true, encoding: .utf8)

        port = try Self.freePort()
        let config = folder.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        AuthorizedKeysFile \(authorized.path)
        PasswordAuthentication \(passwords ? "yes" : "no")
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PerSourcePenalties no
        PidFile \(folder.appendingPathComponent("sshd.pid").path)
        LogLevel \(ProcessInfo.processInfo.environment["OWNDESK_SSHD_LOG"] == nil ? "INFO" : "DEBUG1")
        """.write(to: config, atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", config.path]
        // Nothing inherited: a server holding the test runner's pipes keeps `swift test` waiting
        // for them to close, long after the tests are over.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // OWNDESK_SSHD_LOG=<file> keeps the server's own account of each connection, for when a
        // test fails and only the server knows why.
        if let log = ProcessInfo.processInfo.environment["OWNDESK_SSHD_LOG"],
           FileManager.default.createFile(atPath: log, contents: nil), let handle = FileHandle(forWritingAtPath: log) {
            process.standardError = handle
        } else {
            process.standardError = FileHandle.nullDevice
        }
        try process.run()

        // Ready once it accepts a connection. Probe sparingly: every probe is a connection that never
        // logs in, which is what OpenSSH penalises.
        var tries = 0
        while tries < 100, !Self.accepts(port: port) {
            tries += 1
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: folder)
    }

    /// `ssh-keygen -l`'s fingerprint of the host key, for checking ours against OpenSSH's own.
    func openSSHFingerprint() throws -> String {
        let output = try Self.run("/usr/bin/ssh-keygen", ["-l", "-f", folder.appendingPathComponent("host_key.pub").path])
        return output.split(separator: " ").map(String.init).first { $0.hasPrefix("SHA256:") } ?? ""
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func accepts(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
