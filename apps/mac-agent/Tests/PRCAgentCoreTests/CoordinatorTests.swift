import Foundation
import PRCIdentity
import PRCProtocol
import Testing
@testable import PRCAgentCore

@Suite struct PairingTests {
    @Test func pairingApprovedStoresTheDevice() async throws {
        let h = Harness()
        let qr = await h.coordinator.openPairing()
        try qr.validate()
        #expect(qr.host_device_id == h.hostId)
        let code = try #require(qr.pairingCodeBytes)

        let proof = Pairing.proof(pairingCode: code, pairingSessionId: qr.pairing_session_id, controllerDeviceId: h.controller.deviceId)
        let request = PairRequestPayload(public_key: h.controller.identity.publicKeyB64, device_name: "Browser", device_type: .web, pairing_session_id: qr.pairing_session_id, proof: proof)
        let replies = try await h.send(.pairRequest(request))
        #expect(replies.isEmpty, "nothing is sent before the user approves")
        try await waitUntil("pairing request event") { h.events.get().contains { if case .pairingRequest = $0 { return true } else { return false } } }

        await h.coordinator.resolvePairing(approved: true)
        let results = try h.controller.accept(h.transport.drain(h.controller.connection))
        guard results.count == 1, case .pairResult(let result) = results[0].1 else { Issue.record("expected PAIR_RESULT"); return }
        #expect(result.approved)
        #expect(result.reason == nil)
        #expect(result.host_public_key == h.hostIdentity.publicKeyB64)
        #expect(try DeviceID.deviceId(publicKeyRaw: #require(Base64URL.decode(result.host_public_key))) == qr.host_key_hash)
        #expect(h.trust.device(h.controller.deviceId)?.name == "Browser")
        #expect(h.trust.device(h.controller.deviceId)?.type == .web)
    }

    @Test func badProofsAreCountedAndCloseTheWindow() async throws {
        let h = Harness()
        let qr = await h.coordinator.openPairing()
        for attempt in 1...3 {
            let request = PairRequestPayload(public_key: h.controller.identity.publicKeyB64, device_name: "Browser", device_type: .web, pairing_session_id: qr.pairing_session_id, proof: Base64URL.encode(Data(repeating: UInt8(attempt), count: 32)))
            let replies = try await h.send(.pairRequest(request))
            guard replies.count == 1, case .pairResult(let r) = replies[0].1 else { Issue.record("expected PAIR_RESULT on attempt \(attempt)"); return }
            #expect(r.approved == false && r.reason == .badProof)
        }
        // Window is now closed: the receiver no longer accepts PAIR_REQUEST at all.
        let code = try #require(qr.pairingCodeBytes)
        let good = PairRequestPayload(public_key: h.controller.identity.publicKeyB64, device_name: "Browser", device_type: .web, pairing_session_id: qr.pairing_session_id, proof: Pairing.proof(pairingCode: code, pairingSessionId: qr.pairing_session_id, controllerDeviceId: h.controller.deviceId))
        let after = try await h.send(.pairRequest(good))
        #expect(after.isEmpty)
        #expect(h.trust.device(h.controller.deviceId) == nil)
    }

    @Test func deniedPairingSendsDenied() async throws {
        let h = Harness()
        let qr = await h.coordinator.openPairing()
        let code = try #require(qr.pairingCodeBytes)
        let request = PairRequestPayload(public_key: h.controller.identity.publicKeyB64, device_name: "Browser", device_type: .web, pairing_session_id: qr.pairing_session_id, proof: Pairing.proof(pairingCode: code, pairingSessionId: qr.pairing_session_id, controllerDeviceId: h.controller.deviceId))
        _ = try await h.send(.pairRequest(request))
        await h.coordinator.resolvePairing(approved: false)
        let results = try h.controller.accept(h.transport.drain(h.controller.connection))
        guard results.count == 1, case .pairResult(let r) = results[0].1 else { Issue.record("expected PAIR_RESULT"); return }
        #expect(r.approved == false && r.reason == .denied)
        #expect(h.trust.all.isEmpty)
    }

    @Test func pairRequestWithoutOpenWindowIsIgnored() async throws {
        let h = Harness()
        let request = PairRequestPayload(public_key: h.controller.identity.publicKeyB64, device_name: "Browser", device_type: .web, pairing_session_id: "AAECAwQFBgcICQoLDA0ODw", proof: Base64URL.encode(Data(count: 32)))
        let replies = try await h.send(.pairRequest(request))
        #expect(replies.isEmpty)
        #expect(h.trust.all.isEmpty)
    }
}

@Suite struct SessionTests {
    @Test func fullSessionFlowWithMedia() async throws {
        let h = Harness()
        h.trustController()
        let (sessionId, accept) = try await h.authenticate()
        #expect(accept.display.display_id == "7")
        #expect(accept.display.width_px == 3840)
        #expect(accept.resume_window_s == 600)
        let media = try #require(h.media.get())
        #expect(media.started)
        #expect(media.path == .lan)
        #expect(h.input.displays.last?.displayID == 7)

        let answers = try await h.send(.sdpOffer(SdpOfferPayload(sdp: "v=0\r\noffer\r\n", ice_restart: false)), session: sessionId)
        guard answers.count == 1, case .sdpAnswer(let answer) = answers[0].1 else { Issue.record("expected SDP_ANSWER"); return }
        #expect(answer.sdp.contains("answer-for"))
        #expect(media.offers.count == 1)

        _ = try await h.send(.iceCandidate(IceCandidatePayload(candidate: "candidate:1 1 udp 1 10.0.0.2 5000 typ host", sdp_mid: "0", sdp_mline_index: 0)), session: sessionId)
        #expect(media.candidates.count == 1)

        // Host-side ICE candidate travels back as a signed envelope.
        await h.coordinator.mediaCandidate(IceCandidatePayload(candidate: "candidate:2 1 udp 1 10.0.0.1 6000 typ host", sdp_mid: "0", sdp_mline_index: 0))
        let outbound = try h.controller.accept(h.transport.drain(h.controller.connection))
        #expect(outbound.count == 1 && outbound[0].0.type == "ICE_CANDIDATE" && outbound[0].0.session == sessionId)

        await h.coordinator.mediaState(.connected(path: "Direct (LAN)"))
        await h.coordinator.mediaChannelOpened(.control)
        #expect(media.sent.contains(.displayInfo(FakeMediaSession.display.info)))

        await h.coordinator.mediaFrame(DataChannelFrame(ts: 1, message: .ping(nonce: 42)), on: .control)
        #expect(media.sent.contains(.pong(nonce: 42)))

        await h.coordinator.mediaFrame(DataChannelFrame(ts: 2, message: .mouseMove(displayId: "7", x: 0.5, y: 0.5)), on: .inputLossy)
        await h.coordinator.mediaFrame(DataChannelFrame(ts: 3, message: .keyDown(code: "KeyA", modifiers: [.meta], repeat: false)), on: .inputReliable)
        #expect(h.input.injected == [.mouseMove(displayId: "7", x: 0.5, y: 0.5), .keyDown(code: "KeyA", modifiers: [.meta], repeat: false)])

        await h.coordinator.mediaFrame(DataChannelFrame(ts: 4, message: .bye(.user)), on: .control)
        #expect(media.stopped)
        #expect(h.input.released >= 1)
        #expect(await h.coordinator.hasActiveSession == false)
        try await waitUntil("session ended event") { h.events.get().contains { if case .sessionEnded(.user) = $0 { return true } else { return false } } }
    }

    @Test func streamSettingsReachTheEncoder() async throws {
        let h = Harness()
        h.trustController()
        _ = try await h.authenticate()
        let media = try #require(h.media.get())

        await h.coordinator.mediaFrame(DataChannelFrame(ts: 1, message: .streamSettings(maxHeight: 720, maxFps: 30, prefer: .latency)), on: .control)
        #expect(media.streamSettings?.maxHeight == 720)
        #expect(media.streamSettings?.maxFps == 30)
        #expect(media.streamSettings?.preferLatency == true)

        // Automatic again: nils clear the caps rather than being ignored.
        await h.coordinator.mediaFrame(DataChannelFrame(ts: 2, message: .streamSettings(maxHeight: nil, maxFps: nil, prefer: .quality)), on: .control)
        #expect(media.streamSettings?.maxHeight == nil)
        #expect(media.streamSettings?.preferLatency == false)
    }

    @Test func unknownDeviceGetsOneSignedRejectPerMinute() async throws {
        let h = Harness()
        let first = try await h.send(Harness.request)
        guard first.count == 1, case .sessionReject(let r) = first[0].1 else { Issue.record("expected SESSION_REJECT"); return }
        #expect(r.reason == .untrusted)
        // Same stranger again: silence.
        let second = try await h.send(Harness.request)
        #expect(second.isEmpty)
        h.clock.advance(ms: 61_000)
        let third = try await h.send(Harness.request)
        #expect(third.count == 1)
    }

    @Test func wrongNonceFailsAuthentication() async throws {
        let h = Harness()
        h.trustController()
        let replies = try await h.send(Harness.request)
        guard case .sessionChallenge(let challenge) = replies[0].1 else { Issue.record("expected challenge"); return }
        let bad = SignalingPayload.sessionAuth(SessionAuthPayload(client_nonce: challenge.client_nonce, host_nonce: "AAAAAAAAAAAAAAAAAAAAAA"))
        let result = try await h.send(bad, session: challenge.session_id)
        guard result.count == 1, case .sessionReject(let r) = result[0].1 else { Issue.record("expected SESSION_REJECT"); return }
        #expect(r.reason == .authFailed)
        #expect(await h.coordinator.hasActiveSession == false)
        #expect(h.media.get() == nil, "media never started")
    }

    @Test func secondControllerIsBusy() async throws {
        let h = Harness()
        h.trustController()
        _ = try await h.authenticate()
        let other = TestController(hostPublicKey: h.hostIdentity.publicKeyRaw, now: h.clock.now)
        h.trustController(other)
        let replies = try await h.send(Harness.request, from: other)
        guard replies.count == 1, case .sessionReject(let r) = replies[0].1 else { Issue.record("expected SESSION_REJECT"); return }
        #expect(r.reason == .busy)
    }

    @Test func remoteAccessOffRejectsAndEndsSessions() async throws {
        let h = Harness()
        h.trustController()
        let (sessionId, _) = try await h.authenticate()
        await h.coordinator.setRemoteAccess(false)
        let ended = try h.controller.accept(h.transport.drain(h.controller.connection))
        #expect(ended.contains { $0.0.type == "SESSION_END" && $0.0.session == sessionId })
        if case .sessionEnd(let e)? = ended.first(where: { $0.0.type == "SESSION_END" })?.1 { #expect(e.reason == .remoteAccessDisabled) }
        #expect(h.media.get()?.stopped == true)

        let replies = try await h.send(Harness.request)
        guard replies.count == 1, case .sessionReject(let r) = replies[0].1 else { Issue.record("expected SESSION_REJECT"); return }
        #expect(r.reason == .remoteAccessDisabled)
    }

    @Test func revocationEndsTheSessionAndBlocksReconnect() async throws {
        let h = Harness()
        h.trustController()
        _ = try await h.authenticate()
        await h.coordinator.revoke(deviceId: h.controller.deviceId)
        let ended = try h.controller.accept(h.transport.drain(h.controller.connection))
        if case .sessionEnd(let e)? = ended.last?.1 { #expect(e.reason == .revoked) } else { Issue.record("expected SESSION_END revoked") }
        #expect(h.transport.closed.contains(h.controller.connection))
        #expect(h.trust.device(h.controller.deviceId) == nil)
        let replies = try await h.send(Harness.request)
        guard replies.count == 1, case .sessionReject(let r) = replies[0].1 else { Issue.record("expected SESSION_REJECT"); return }
        #expect(r.reason == .untrusted)
    }

    @Test func resumeWithinWindowAndRejectAfterwards() async throws {
        let h = Harness()
        h.trustController()
        let (sessionId, _) = try await h.authenticate()
        await h.coordinator.connectionClosed(h.controller.connection)

        h.clock.advance(ms: 30_000)
        let resumed = try await h.send(.sessionResume(SessionResumePayload()), session: sessionId)
        guard resumed.count == 1, case .sessionAccept(let accept) = resumed[0].1 else { Issue.record("expected SESSION_ACCEPT on resume"); return }
        #expect(accept.display.display_id == "7")

        let bogus = try await h.send(.sessionResume(SessionResumePayload()), session: "ICEiIyQlJicoKSorLC0uLw")
        guard bogus.count == 1, case .sessionReject(let r) = bogus[0].1 else { Issue.record("expected SESSION_REJECT"); return }
        #expect(r.reason == .expired)
    }

    @Test func mediaStartFailureIsReportedAsHostError() async throws {
        let h = Harness(failMediaStart: true)
        h.trustController()
        let replies = try await h.send(Harness.request)
        guard case .sessionChallenge(let challenge) = replies[0].1 else { Issue.record("expected challenge"); return }
        let result = try await h.send(.sessionAuth(SessionAuthPayload(client_nonce: challenge.client_nonce, host_nonce: challenge.host_nonce)), session: challenge.session_id)
        guard result.count == 1, case .sessionReject(let r) = result[0].1 else { Issue.record("expected SESSION_REJECT"); return }
        #expect(r.reason == .hostError)
        #expect(await h.coordinator.hasActiveSession == false)
    }

    @Test func signalingOnlyModeEndsSessionOnOffer() async throws {
        let h = Harness(mediaEnabled: false)
        h.trustController()
        let (sessionId, _) = try await h.authenticate()
        let replies = try await h.send(.sdpOffer(SdpOfferPayload(sdp: "v=0", ice_restart: false)), session: sessionId)
        guard replies.count == 1, case .sessionEnd(let e) = replies[0].1 else { Issue.record("expected SESSION_END"); return }
        #expect(e.reason == .error)
    }

    @Test func tamperedEnvelopeClosesTheConnection() async throws {
        let h = Harness()
        h.trustController()
        var env = try h.controller.sender.build(Harness.request, to: h.hostId, session: "")
        env.payload = Envelope.encodePayload(json: Data("{}".utf8))
        await h.coordinator.handleText(String(decoding: try env.serialized(), as: UTF8.self), from: h.controller.connection)
        #expect(h.transport.closed.contains(h.controller.connection))
        #expect(h.transport.drain(h.controller.connection).isEmpty)
    }

    @Test func malformedDataChannelFloodEndsSession() async throws {
        let h = Harness()
        h.trustController()
        _ = try await h.authenticate()
        for _ in 0..<Limits.malformedPerMinuteBeforeDisconnect { await h.coordinator.mediaRejected(.malformed) }
        #expect(await h.coordinator.hasActiveSession == false)
        #expect(h.media.get()?.stopped == true)
    }
}

@Suite struct TrustStoreTests {
    @Test func persistsAcrossReload() throws {
        let dir = tempDirectory()
        let store = try TrustStore(directory: dir)
        let id = SoftwareIdentity()
        try store.add(TrustedDevice(deviceId: id.deviceId, publicKey: id.publicKeyB64, name: "Phone", type: .android, pairedAt: 1, lastSeen: nil))
        store.touch(id.deviceId, at: 99)

        let reloaded = try TrustStore(directory: dir)
        #expect(reloaded.device(id.deviceId)?.name == "Phone")
        #expect(reloaded.device(id.deviceId)?.lastSeen == 99)
        #expect(reloaded.publicKey(for: id.deviceId) == id.publicKeyRaw)
        #expect(try reloaded.revoke(id.deviceId))
        #expect(try TrustStore(directory: dir).all.isEmpty)

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("trusted-devices.json").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}
