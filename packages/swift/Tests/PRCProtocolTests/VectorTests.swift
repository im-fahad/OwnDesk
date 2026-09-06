import CryptoKit
import Foundation
import PRCIdentity
import PRCProtocol
import Testing

@Suite struct IdentityVectorTests {
    let vec = try! Vectors.load("identity.json", as: IdentityVector.self)

    @Test func deviceIdsAndFingerprintsMatch() throws {
        for (name, key) in vec.keys {
            let raw = try #require(Base64URL.decode(key.public_key), "\(name)")
            #expect(raw.count == 65)
            #expect(try DeviceID.deviceId(publicKeyRaw: raw) == key.device_id, "\(name)")
            #expect(try DeviceID.fingerprint(deviceId: key.device_id) == key.fingerprint, "\(name)")
        }
    }

    @Test func invalidPublicKeysAreRejected() throws {
        for bad in vec.invalid_public_keys {
            let raw = try #require(Base64URL.decode(bad.public_key))
            #expect(throws: IdentityError.invalidPublicKey, "\(bad.why)") { try DeviceID.deviceId(publicKeyRaw: raw) }
            #expect(Verifier.verify(publicKeyRaw: raw, data: Data("x".utf8), signature: Data(count: 64)) == false)
        }
        #expect(throws: IdentityError.invalidDeviceId) { try DeviceID.fingerprint(deviceId: "xyz") }
    }
}

@Suite struct EnvelopeVectorTests {
    let signing = try! Vectors.load("signing-input.json", as: SigningInputVector.self)
    let envelopes = try! Vectors.load("envelopes.json", as: EnvelopesVector.self)

    @Test func signingInputMatchesByteForByte() throws {
        let u = signing.unsigned
        let input = Envelope.signingInput(v: u.v, type: u.type, from: u.from, to: u.to, session: u.session, seq: u.seq, ts: u.ts, payload: u.payload)
        #expect(String(decoding: input, as: UTF8.self) == signing.signing_input)
        #expect(Hex.encode(Data(SHA256.hash(data: input))) == signing.signing_input_sha256_hex)
        let payload = try #require(Base64URL.decode(u.payload))
        #expect(String(decoding: payload, as: UTF8.self) == signing.payload_json)
    }

    func makeReceiver() -> EnvelopeReceiver {
        let trusted = envelopes.receiver.trusted.compactMapValues { Base64URL.decode($0) }
        let now = envelopes.receiver.now_ms
        return EnvelopeReceiver(
            selfDeviceId: envelopes.receiver.self_device_id,
            resolveKey: { trusted[$0] },
            now: { now },
            acceptPairRequests: envelopes.receiver.accept_pair_requests
        )
    }

    @Test func receiverCasesInOrder() throws {
        var receiver = makeReceiver()
        for c in envelopes.cases {
            let raw = try JSONEncoder().encode(c.envelope)
            let result = receiver.receive(raw)
            #expect(result.reasonString == c.expect, "\(c.name)")
        }
    }

    @Test func acceptedPayloadIsTyped() throws {
        var receiver = makeReceiver()
        let first = envelopes.cases[0]
        guard case .accepted(let env, let payload, let key) = receiver.receive(try JSONEncoder().encode(first.envelope)) else {
            Issue.record("first case should be accepted"); return
        }
        #expect(env.type == "SESSION_REQUEST")
        #expect(Base64URL.encode(key) == envelopes.receiver.trusted[env.from])
        guard case .sessionRequest(let req) = payload else { Issue.record("expected SESSION_REQUEST payload"); return }
        #expect(req.path == .lan)
        #expect(req.capabilities.codecs == [.h264])
        #expect(req.capabilities.max_height == 1080)
    }

    @Test func garbageIsMalformedNotACrash() {
        var receiver = makeReceiver()
        for raw in ["", "{", "null", "[]", "{\"v\":1}", "{\"v\":1.5}"] {
            #expect(receiver.receive(Data(raw.utf8)).reasonString == "malformed", "\(raw)")
        }
        #expect(receiver.receive(Data([0xFF, 0xFE])).reasonString == "malformed")
        #expect(receiver.receive(Data(count: Envelope.maxBytes + 1)).reasonString == "too_large")
    }

    @Test func pairRequestRefusedWhenPairingClosed() throws {
        var receiver = makeReceiver()
        receiver.acceptPairRequests = false
        let pair = try #require(envelopes.cases.first { $0.name.hasPrefix("PAIR_REQUEST self-certified") })
        #expect(receiver.receive(try JSONEncoder().encode(pair.envelope)).reasonString == "unknown_sender")
    }
}

@Suite struct PairingVectorTests {
    let vec = try! Vectors.load("pairing.json", as: PairingVector.self)

    @Test func proofMatchesVector() throws {
        let code = try #require(Base64URL.decode(vec.pairing_code))
        #expect(String(decoding: Pairing.proofInput(pairingSessionId: vec.pairing_session_id, controllerDeviceId: vec.controller_device_id), as: UTF8.self) == vec.proof_input)
        #expect(Pairing.proof(pairingCode: code, pairingSessionId: vec.pairing_session_id, controllerDeviceId: vec.controller_device_id) == vec.proof)
        #expect(Pairing.verifyProof(pairingCode: code, pairingSessionId: vec.pairing_session_id, controllerDeviceId: vec.controller_device_id, proof: vec.proof))
        let wrong = try #require(Base64URL.decode(vec.wrong_code))
        #expect(!Pairing.verifyProof(pairingCode: wrong, pairingSessionId: vec.pairing_session_id, controllerDeviceId: vec.controller_device_id, proof: vec.proof))
        #expect(!Pairing.verifyProof(pairingCode: code, pairingSessionId: vec.pairing_session_id, controllerDeviceId: String(repeating: "ef", count: 32), proof: vec.proof))
        #expect(!Pairing.verifyProof(pairingCode: code, pairingSessionId: vec.pairing_session_id, controllerDeviceId: vec.controller_device_id, proof: "short"))
    }

    @Test func qrPayloadRoundTripsWithExplicitNull() throws {
        let qr = QRPayload(hostDeviceId: vec.controller_device_id, hostName: "Mac Mini M4", addresses: ["192.168.1.20:47500"], rendezvousUrl: nil, pairingSessionId: vec.pairing_session_id, pairingCode: Pairing.randomSecret(), now: 1_000_000)
        try qr.validate()
        let json = try JSONEncoder().encode(qr)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"rendezvous_url\":null"))
        #expect(try JSONDecoder().decode(QRPayload.self, from: json) == qr)
        #expect(qr.expires_at == 1_000_000 + Pairing.ttlMs)
        #expect(qr.pairingCodeBytes?.count == 16)
    }
}

@Suite struct ServerAuthVectorTests {
    let vec = try! Vectors.load("server-auth.json", as: ServerAuthVector.self)

    @Test func signingInputAndSignature() throws {
        #expect(String(decoding: ServerAuth.signingInput(nonce: vec.nonce, origin: vec.origin, deviceId: vec.device_id), as: UTF8.self) == vec.signing_input)
        let pub = try #require(Base64URL.decode(vec.public_key))
        #expect(ServerAuth.verify(publicKeyRaw: pub, nonce: vec.nonce, origin: vec.origin, deviceId: vec.device_id, signature: vec.signature))
        #expect(!ServerAuth.verify(publicKeyRaw: pub, nonce: vec.nonce, origin: vec.wrong_origin, deviceId: vec.device_id, signature: vec.signature))
        #expect(!ServerAuth.verify(publicKeyRaw: pub, nonce: "B" + vec.nonce.dropFirst(), origin: vec.origin, deviceId: vec.device_id, signature: vec.signature))
        #expect(!ServerAuth.verify(publicKeyRaw: pub, nonce: vec.nonce, origin: vec.origin, deviceId: String(repeating: "ef", count: 32), signature: vec.signature))
    }
}
