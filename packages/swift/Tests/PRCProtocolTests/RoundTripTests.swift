import Foundation
import PRCIdentity
import PRCProtocol
import Testing

@Suite struct RoundTripTests {
    let keys = try! Vectors.load("test-keys.json", as: TestKeys.self)
    let identityVec = try! Vectors.load("identity.json", as: IdentityVector.self)

    @Test func softwareIdentityFromTestKeyMatchesVector() throws {
        let controller = try SoftwareIdentity(jwkD: try #require(keys.keys["controller"]).d)
        let expected = try #require(identityVec.keys["controller"])
        #expect(controller.publicKeyB64 == expected.public_key)
        #expect(controller.deviceId == expected.device_id)
        #expect(controller.fingerprint == expected.fingerprint)
    }

    @Test func signAndVerifyAcrossSenderAndReceiver() throws {
        let host = SoftwareIdentity()
        let controller = SoftwareIdentity()
        let now: Int64 = 5_000_000
        var sender = EnvelopeSender(identity: controller, now: { now })
        var receiver = EnvelopeReceiver(selfDeviceId: host.deviceId, resolveKey: { $0 == controller.deviceId ? controller.publicKeyRaw : nil }, now: { now })

        let request = SignalingPayload.sessionRequest(SessionRequestPayload(
            client_nonce: "AAECAwQFBgcICQoLDA0ODw", versions: [1], path: .lan,
            capabilities: SessionCapabilities(codecs: [.h264], max_height: 1080, max_fps: 60)))
        let e1 = try sender.build(request, to: host.deviceId, session: "")
        #expect(e1.seq == 1)
        #expect(e1.shapeProblem() == nil)

        let r1 = receiver.receive(try e1.serialized())
        guard case .accepted(_, let payload, _) = r1 else { Issue.record("expected accept, got \(r1.reasonString)"); return }
        #expect(payload == request)

        #expect(receiver.receive(try e1.serialized()).reasonString == "replayed")

        var tampered = try sender.build(request, to: host.deviceId, session: "")
        tampered.payload = Envelope.encodePayload(json: Data("{}".utf8))
        #expect(receiver.receive(try tampered.serialized()).reasonString == "bad_signature")

        let forged = try Envelope.signed(type: "SESSION_AUTH", from: controller.deviceId, to: host.deviceId, session: "", seq: 3, ts: now, payload: Envelope.encodePayload(json: Data("{}".utf8)), identity: host)
        #expect(receiver.receive(try forged.serialized()).reasonString == "bad_signature")

        let sessionId = "ICEiIyQlJicoKSorLC0uLw"
        let offer = try sender.build(.sdpOffer(SdpOfferPayload(sdp: "v=0", ice_restart: false)), to: host.deviceId, session: sessionId)
        #expect(offer.seq == 1)
        #expect(receiver.receive(try offer.serialized()).reasonString == "ok")

        receiver.forgetSession(from: controller.deviceId, session: "")
        #expect(receiver.receive(try e1.serialized()).reasonString == "ok")
    }

    @Test func nullableFieldsAreEncodedAndRequired() throws {
        let result = PairResultPayload(approved: true, reason: nil, host_public_key: String(repeating: "A", count: 87), host_name: "Mac Mini", rendezvous_url: nil)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(json.contains("\"reason\":null"))
        #expect(json.contains("\"rendezvous_url\":null"))
        #expect(try JSONDecoder().decode(PairResultPayload.self, from: Data(json.utf8)) == result)
        let missing = Data("{\"approved\":true,\"host_public_key\":\"\(String(repeating: "A", count: 87))\",\"host_name\":\"x\"}".utf8)
        #expect(throws: (any Error).self) { try SignalingPayload.decode(type: .pairResult, from: missing) }

        let ice = IceCandidatePayload(candidate: "candidate:1 1 udp 1 1.2.3.4 5 typ host", sdp_mid: nil, sdp_mline_index: nil)
        let iceJson = String(decoding: try JSONEncoder().encode(ice), as: UTF8.self)
        #expect(iceJson.contains("\"sdp_mid\":null"))
        #expect(iceJson.contains("\"sdp_mline_index\":null"))
    }

    @Test func payloadValidationMirrorsSchemas() throws {
        func rejects(_ type: SignalingType, _ json: String, _ label: String) {
            #expect(throws: (any Error).self, "\(label)") { try SignalingPayload.decode(type: type, from: Data(json.utf8)) }
        }
        rejects(.sessionRequest, "{\"client_nonce\":\"short\",\"versions\":[1],\"path\":\"lan\",\"capabilities\":{\"codecs\":[\"H264\"],\"max_height\":1080,\"max_fps\":60}}", "nonce length")
        rejects(.sessionRequest, "{\"client_nonce\":\"AAECAwQFBgcICQoLDA0ODw\",\"versions\":[1],\"path\":\"lan\",\"capabilities\":{\"codecs\":[\"VP8\"],\"max_height\":1080,\"max_fps\":60}}", "codec enum")
        rejects(.sessionRequest, "{\"client_nonce\":\"AAECAwQFBgcICQoLDA0ODw\",\"versions\":[1],\"path\":\"lan\",\"capabilities\":{\"codecs\":[\"H264\"],\"max_height\":100,\"max_fps\":60}}", "height range")
        rejects(.sessionRequest, "{\"client_nonce\":\"AAECAwQFBgcICQoLDA0ODw\",\"versions\":[1],\"path\":\"vpn\",\"capabilities\":{\"codecs\":[\"H264\"],\"max_height\":1080,\"max_fps\":60}}", "path enum")
        rejects(.sessionReject, "{\"reason\":\"whatever\"}", "reject reason enum")
        rejects(.sessionEnd, "{\"reason\":\"execute_shell\"}", "end reason enum")
        rejects(.sdpOffer, "{\"sdp\":\"\",\"ice_restart\":false}", "empty sdp")
        rejects(.sessionResume, "[]", "array is not an object")
        rejects(.sessionAccept, "{\"client_nonce\":\"AAECAwQFBgcICQoLDA0ODw\",\"host_nonce\":\"AAECAwQFBgcICQoLDA0ODw\",\"display\":{\"display_id\":\"main\",\"width_px\":0,\"height_px\":1080,\"scale\":2},\"resume_window_s\":600}", "display width")

        let ok = try SignalingPayload.decode(type: .sessionResume, from: Data("{}".utf8))
        #expect(ok == .sessionResume(SessionResumePayload()))
        let accept = try SignalingPayload.decode(type: .sessionAccept, from: Data("{\"client_nonce\":\"AAECAwQFBgcICQoLDA0ODw\",\"host_nonce\":\"AAECAwQFBgcICQoLDA0ODw\",\"display\":{\"display_id\":\"main\",\"width_px\":1920,\"height_px\":1080,\"scale\":2},\"resume_window_s\":600}".utf8))
        #expect(accept.type == .sessionAccept)
    }
}
