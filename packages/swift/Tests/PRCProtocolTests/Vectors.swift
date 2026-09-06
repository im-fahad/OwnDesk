import Foundation
import PRCProtocol

/// Loads packages/protocol/vectors/*.json relative to this source file.
enum Vectors {
    static let directory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // -> packages/
        return url.appendingPathComponent("protocol/vectors", isDirectory: true)
    }()

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }
}

struct IdentityVector: Decodable {
    struct Key: Decodable { let public_key: String; let device_id: String; let fingerprint: String }
    struct Bad: Decodable { let public_key: String; let why: String }
    let keys: [String: Key]
    let invalid_public_keys: [Bad]
}

struct SigningInputVector: Decodable {
    struct Unsigned: Decodable {
        let v: Int; let type: String; let from: String; let to: String; let session: String
        let seq: Int; let ts: Int64; let payload: String
    }
    let payload_json: String
    let unsigned: Unsigned
    let signing_input: String
    let signing_input_sha256_hex: String
}

struct EnvelopesVector: Decodable {
    struct Receiver: Decodable { let self_device_id: String; let trusted: [String: String]; let now_ms: Int64; let accept_pair_requests: Bool }
    struct Case: Decodable { let name: String; let envelope: Envelope; let expect: String }
    let receiver: Receiver
    let cases: [Case]
}

struct PairingVector: Decodable {
    let pairing_code: String; let pairing_session_id: String; let controller_device_id: String
    let proof_input: String; let proof: String; let wrong_code: String
}

struct ServerAuthVector: Decodable {
    let nonce: String; let origin: String; let device_id: String; let public_key: String
    let signing_input: String; let signature: String; let wrong_origin: String
}

struct TestKeys: Decodable {
    struct JWK: Decodable { let d: String; let x: String; let y: String }
    let keys: [String: JWK]
}
