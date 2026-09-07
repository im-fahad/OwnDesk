import Foundation
import PRCProtocol
import WebRTC

public protocol WebRTCClientDelegate: AnyObject {
    func webrtc(_ client: WebRTCClient, didGenerateCandidate candidate: IceCandidatePayload)
    func webrtc(_ client: WebRTCClient, didChangeConnectionState state: RTCPeerConnectionState)
    func webrtc(_ client: WebRTCClient, didOpenChannel label: ChannelLabel)
    func webrtc(_ client: WebRTCClient, didReceive frame: DataChannelFrame, on label: ChannelLabel)
    func webrtcDidReceiveRemoteVideo(_ client: WebRTCClient)
}

public enum WebRTCClientError: Error, Sendable {
    case peerConnectionUnavailable
    case sdp(String)
}

/// The controller's peer connection: offerer, receives the screen track, owns the three data channels (spec section 12).
public final class WebRTCClient: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let pc: RTCPeerConnection
    private var channels: [ChannelLabel: RTCDataChannel] = [:]
    private var renderers: [RTCVideoRenderer] = []
    private let lock = NSLock()
    public private(set) var remoteTrack: RTCVideoTrack?
    public weak var delegate: WebRTCClientDelegate?

    public init(iceServers: [RTCIceServer]) throws {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = iceServers
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCClient.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw WebRTCClientError.peerConnectionUnavailable
        }
        self.pc = pc
        super.init()
        pc.delegate = self

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: transceiverInit)

        for label in ChannelLabel.allCases {
            let cfg = RTCDataChannelConfiguration()
            cfg.isOrdered = label.ordered
            if let r = label.maxRetransmits { cfg.maxRetransmits = Int32(r) }
            guard let channel = pc.dataChannel(forLabel: label.rawValue, configuration: cfg) else { continue }
            channel.delegate = self
            channels[label] = channel
        }
    }

    // MARK: Signaling

    public func offer(iceRestart: Bool) async throws -> String {
        let mandatory: [String: String]? = iceRestart ? [kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue] : nil
        let constraints = RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: constraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: WebRTCClientError.sdp(error?.localizedDescription ?? "no offer")) }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offer) { error in
                if let error { c.resume(throwing: WebRTCClientError.sdp(error.localizedDescription)) } else { c.resume() }
            }
        }
        return offer.sdp
    }

    public func setAnswer(_ sdp: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                if let error { c.resume(throwing: WebRTCClientError.sdp(error.localizedDescription)) } else { c.resume() }
            }
        }
    }

    public func add(candidate: IceCandidatePayload) {
        let ice = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: Int32(candidate.sdp_mline_index ?? 0), sdpMid: candidate.sdp_mid)
        pc.add(ice) { error in
            if let error { Log.media.notice("add candidate: \(error.localizedDescription, privacy: .public)") }
        }
    }

    public var connectionState: RTCPeerConnectionState { pc.connectionState }

    // MARK: Data

    public func send(_ message: DataChannelMessage, ts: Int64) {
        lock.lock(); let channel = channels[message.channel]; lock.unlock()
        guard let channel, channel.readyState == .open, let data = try? DataChannelCodec.encode(message, ts: ts) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    public func isOpen(_ label: ChannelLabel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return channels[label]?.readyState == .open
    }

    // MARK: Video

    public func attach(renderer: RTCVideoRenderer) {
        lock.lock()
        renderers.append(renderer)
        let track = remoteTrack
        lock.unlock()
        track?.add(renderer)
    }

    public func detach(renderer: RTCVideoRenderer) {
        lock.lock()
        renderers.removeAll { $0 === renderer }
        let track = remoteTrack
        lock.unlock()
        track?.remove(renderer)
    }

    public func close() {
        lock.lock()
        let open = Array(channels.values)
        channels.removeAll()
        let track = remoteTrack
        let attached = renderers
        renderers.removeAll()
        lock.unlock()
        for r in attached { track?.remove(r) }
        open.forEach { $0.close() }
        pc.close()
    }

    /// Same rule as the agent (spec section 9.3).
    public func selectedPath(_ completion: @escaping @Sendable (String?) -> Void) {
        pc.statistics { report in
            let stats = report.statistics
            guard let transport = stats.values.first(where: { $0.type == "transport" }),
                  let pairId = transport.values["selectedCandidatePairId"] as? String,
                  let pair = stats[pairId],
                  let localId = pair.values["localCandidateId"] as? String,
                  let remoteId = pair.values["remoteCandidateId"] as? String,
                  let local = stats[localId], let remote = stats[remoteId],
                  let localType = local.values["candidateType"] as? String,
                  let remoteType = remote.values["candidateType"] as? String
            else { completion(nil); return }
            let localAddress = (local.values["address"] as? String) ?? (local.values["ip"] as? String) ?? ""
            let remoteAddress = (remote.values["address"] as? String) ?? (remote.values["ip"] as? String) ?? ""
            completion(PathClassifier.classify(localType: localType, remoteType: remoteType, localAddress: localAddress, remoteAddress: remoteAddress))
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
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        delegate?.webrtc(self, didChangeConnectionState: newState)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        delegate?.webrtc(self, didGenerateCandidate: IceCandidatePayload(candidate: candidate.sdp, sdp_mid: candidate.sdpMid, sdp_mline_index: Int(candidate.sdpMLineIndex)))
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        lock.lock()
        remoteTrack = track
        let attached = renderers
        lock.unlock()
        for r in attached { track.add(r) }
        delegate?.webrtcDidReceiveRemoteVideo(self)
    }

    // MARK: RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open, let label = ChannelLabel(rawValue: dataChannel.label) else { return }
        delegate?.webrtc(self, didOpenChannel: label)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let label = ChannelLabel(rawValue: dataChannel.label), let frame = try? DataChannelCodec.decode(buffer.data, receivedOn: label) else { return }
        delegate?.webrtc(self, didReceive: frame, on: label)
    }
}

public enum PathClassifier {
    public static func classify(localType: String, remoteType: String, localAddress: String, remoteAddress: String) -> String {
        if localType == "relay" || remoteType == "relay" { return "Relayed" }
        if localType == "host" && remoteType == "host" { return "Direct (LAN)" }
        if localType == "host" && isPrivate(localAddress) { return "Direct (LAN)" }
        if remoteType == "host" && isPrivate(remoteAddress) { return "Direct (LAN)" }
        if isPrivate(localAddress) && isPrivate(remoteAddress) { return "Direct (LAN)" }
        return "Direct (Internet)"
    }

    public static func isPrivate(_ address: String) -> Bool {
        let a = address.lowercased()
        if a.hasPrefix("10.") || a.hasPrefix("192.168.") || a.hasPrefix("169.254.") || a.hasPrefix("127.") { return true }
        let parts = a.split(separator: ".")
        if parts.count > 1, let second = Int(parts[1]) {
            if a.hasPrefix("172.") && (16...31).contains(second) { return true }
            if a.hasPrefix("100.") && (64...127).contains(second) { return true }
        }
        return a.hasPrefix("fc") || a.hasPrefix("fd") || a.hasPrefix("fe80") || a == "::1"
    }
}
