import Foundation
import PRCIdentity
import PRCLocalControl
import Testing

@Suite struct LocalControlTests {
    @Test func requestAndResponseOverAUnixSocket() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prc-lc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = dir.appendingPathComponent("control.json")
        let server = LocalControlServer(controlFile: socket) { request in
            switch request.command {
            case "echo": return ControlResponse(ok: true, message: request.args.joined(separator: " "), data: ["count": String(request.args.count)])
            default: return .failure("unknown command \(request.command)")
            }
        }
        try server.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        let reply = try await LocalControlClient.send(ControlRequest(command: "echo", args: ["hello", "there"]), controlFile: socket, timeoutMs: 5000)
        #expect(reply.ok && reply.message == "hello there" && reply.data["count"] == "2")

        let bad = try await LocalControlClient.send(ControlRequest(command: "nope"), controlFile: socket, timeoutMs: 5000)
        #expect(!bad.ok && bad.message.contains("unknown"))

        // A wrong token is refused; the file's mode keeps other users from reading the right one.
        let endpoint = try LocalControlClient.readEndpoint(socket)
        let attrs = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        try JSONEncoder().encode(ControlEndpoint(port: endpoint.port, token: "wrong")).write(to: socket)
        let refused = try await LocalControlClient.send(ControlRequest(command: "echo"), controlFile: socket, timeoutMs: 5000)
        #expect(!refused.ok && refused.message == "bad token")

        server.stop()
        await #expect(throws: LocalControlError.self) {
            try await LocalControlClient.send(ControlRequest(command: "echo"), controlFile: socket, timeoutMs: 2000)
        }
    }

    @Test func fileBackedIdentityPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prc-id-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("identity.json")
        let first = try FileBackedIdentityStore.loadOrCreate(at: url, preferSecureEnclave: false)
        let second = try FileBackedIdentityStore.loadOrCreate(at: url, preferSecureEnclave: false)
        #expect(first.deviceId == second.deviceId)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let signature = try second.sign(Data("x".utf8))
        #expect(Verifier.verify(publicKeyRaw: first.publicKeyRaw, data: Data("x".utf8), signature: signature))
    }

    @Test func testBinaryIsAdHoc() {
        // swift test binaries are ad-hoc signed; the check must say so rather than crash.
        #expect(CodeSigning.isAdHocSigned)
    }
}
