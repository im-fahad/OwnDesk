import CoreMedia
import Foundation
import PRCProtocol
import WebRTC

public protocol WebRTCSessionDelegate: AnyObject {
    func webrtc(_ session: WebRTCSession, didGenerateCandidate candidate: IceCandidatePayload)
    func webrtc(_ session: WebRTCSession, didChangeConnectionState state: RTCPeerConnectionState)
    func webrtc(_ session: WebRTCSession, didOpenChannel label: ChannelLabel)
    func webrtc(_ session: WebRTCSession, didReceive frame: DataChannelFrame, on label: ChannelLabel)
    func webrtc(_ session: WebRTCSession, didRejectMessage error: DataChannelError, on label: String)
}

public enum WebRTCError: Error, Sendable {
    case peerConnectionUnavailable
    case sdp(String)
}

/// One peer connection: the screen video track as sender, plus the three data channels the
/// controller opens. The host is always the answerer (spec section 12).
public final class WebRTCSession: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let pc: RTCPeerConnection
    private let videoSource: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let videoTrack: RTCVideoTrack
    private let videoSender: RTCRtpSender
    private let maxBitrateBps: Int
    private let maxFramerate: Int
    private var channels: [ChannelLabel: RTCDataChannel] = [:]
    private let lock = NSLock()

    public weak var delegate: WebRTCSessionDelegate?

    public init(iceServers: [RTCIceServer], maxBitrateBps: Int, maxFramerate: Int) throws {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = iceServers
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw WebRTCError.peerConnectionUnavailable
        }
        self.pc = pc
        videoSource = WebRTCSession.factory.videoSource()
        capturer = RTCVideoCapturer(delegate: videoSource)
        videoTrack = WebRTCSession.factory.videoTrack(with: videoSource, trackId: "screen0")
        // Adding the track before the offer arrives lets libwebrtc bind it to the offer's video m-line.
        guard let sender = pc.add(videoTrack, streamIds: ["screen"]) else { throw WebRTCError.peerConnectionUnavailable }
        videoSender = sender
        self.maxBitrateBps = maxBitrateBps
        self.maxFramerate = maxFramerate
        super.init()
        pc.delegate = self
    }

    // MARK: Media in

    public func deliver(pixelBuffer: CVPixelBuffer, time: CMTime) {
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let ns = Int64(CMTimeGetSeconds(time) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: ns)
        videoSource.capturer(capturer, didCapture: frame)
    }

    // MARK: Signaling

    public func answer(offerSDP: String) async throws -> String {
        try await setRemote(RTCSessionDescription(type: .offer, sdp: offerSDP))
        let answer = try await createAnswer()
        try await setLocal(answer)
        applyEncodingParameters()
        return answer.sdp
    }

    public func add(candidate: IceCandidatePayload) {
        let ice = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: Int32(candidate.sdp_mline_index ?? 0), sdpMid: candidate.sdp_mid)
        pc.add(ice) { error in
            if let error { Log.media.warning("add candidate failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func setRemote(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { c.resume(throwing: WebRTCError.sdp(error.localizedDescription)) } else { c.resume() }
            }
        }
    }

    private func setLocal(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { c.resume(throwing: WebRTCError.sdp(error.localizedDescription)) } else { c.resume() }
            }
        }
    }

    private func createAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: WebRTCError.sdp(error?.localizedDescription ?? "no answer")) }
            }
        }
    }

    private func applyEncodingParameters() {
        let params = videoSender.parameters
        for encoding in params.encodings {
            encoding.maxBitrateBps = NSNumber(value: maxBitrateBps)
            encoding.maxFramerate = NSNumber(value: maxFramerate)
        }
        params.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
        videoSender.parameters = params
    }

    // MARK: Data out

    public func send(_ message: DataChannelMessage, ts: Int64) {
        lock.lock(); let channel = channels[message.channel]; lock.unlock()
        guard let channel, channel.readyState == .open, let data = try? DataChannelCodec.encode(message, ts: ts) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    public func close() {
        lock.lock(); let open = Array(channels.values); channels.removeAll(); lock.unlock()
        open.forEach { $0.close() }
        pc.close()
    }

    /// "Direct (LAN)", "Direct (Internet)", or "Relayed" from the selected candidate pair (spec section 9.3).
    public func selectedPath(_ completion: @escaping @Sendable (String?) -> Void) {
        pc.statistics { report in
            let stats = report.statistics
            guard let transport = stats.values.first(where: { $0.type == "transport" }),
                  let pairId = transport.values["selectedCandidatePairId"] as? String,
                  let pair = stats[pairId],
                  let localId = pair.values["localCandidateId"] as? String,
                  let remoteId = pair.values["remoteCandidateId"] as? String,
                  let local = stats[localId]?.values["candidateType"] as? String,
                  let remote = stats[remoteId]?.values["candidateType"] as? String
            else { completion(nil); return }
            if local == "relay" || remote == "relay" { completion("Relayed") }
            else if local == "host" && remote == "host" { completion("Direct (LAN)") }
            else { completion("Direct (Internet)") }
        }
    }

    // MARK: RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        delegate?.webrtc(self, didChangeConnectionState: newState)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload = IceCandidatePayload(candidate: candidate.sdp, sdp_mid: candidate.sdpMid, sdp_mline_index: Int(candidate.sdpMLineIndex))
        delegate?.webrtc(self, didGenerateCandidate: payload)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard let label = ChannelLabel(rawValue: dataChannel.label) else {
            Log.media.warning("closing data channel with unknown label")
            dataChannel.close()
            return
        }
        lock.lock(); channels[label] = dataChannel; lock.unlock()
        dataChannel.delegate = self
        if dataChannel.readyState == .open { delegate?.webrtc(self, didOpenChannel: label) }
    }

    // MARK: RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open, let label = ChannelLabel(rawValue: dataChannel.label) else { return }
        delegate?.webrtc(self, didOpenChannel: label)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let label = ChannelLabel(rawValue: dataChannel.label) else { return }
        do {
            let frame = try DataChannelCodec.decode(buffer.data, receivedOn: label)
            delegate?.webrtc(self, didReceive: frame, on: label)
        } catch let error as DataChannelError {
            delegate?.webrtc(self, didRejectMessage: error, on: dataChannel.label)
        } catch {
            delegate?.webrtc(self, didRejectMessage: .malformed, on: dataChannel.label)
        }
    }
}
