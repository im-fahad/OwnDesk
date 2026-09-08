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
    private var maxBitrateBps: Int
    private var minBitrateBps: Int
    private var maxFramerate: Int
    /// A ceiling the controller asked for, in captured pixels. Nil means let the link decide.
    private var requestedMaxHeight: Int?
    private var requestedMaxFramerate: Int?
    private var preferLatency = false
    private var captureHeight: Int = 0
    private let configuredMaxFramerate: Int
    private var startBitrateBps: Int
    private var channels: [ChannelLabel: RTCDataChannel] = [:]

    /// Spec section 15: 20 Mbps cap on the LAN path, 8 Mbps on the cloud path. The start bitrate seeds
    /// libwebrtc's bandwidth estimate so a LAN session does not spend half a minute at 640x360.
    public static func bitrates(for path: ConnectionPath, cap: Int) -> (min: Int, start: Int, max: Int) {
        switch path {
        case .lan: return (min(1_000_000, cap), min(6_000_000, cap), cap)
        case .cloud: return (min(600_000, cap), min(1_500_000, cap, 8_000_000), min(cap, 8_000_000))
        }
    }

    /// Spec section 16 targets 1080p at 30 on a good Internet link. Half the frames means twice the
    /// bits per frame, which is what makes a relayed picture sharp instead of soft.
    public static func framerate(for path: ConnectionPath, cap: Int) -> Int {
        switch path {
        case .lan: return cap
        case .cloud: return min(cap, 30)
        }
    }

    public func setPath(_ path: ConnectionPath) {
        let b = WebRTCSession.bitrates(for: path, cap: configuredMaxBitrateBps)
        minBitrateBps = b.min
        startBitrateBps = b.start
        maxBitrateBps = b.max
        maxFramerate = WebRTCSession.framerate(for: path, cap: configuredMaxFramerate)
    }
    private let configuredMaxBitrateBps: Int
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
        self.configuredMaxBitrateBps = maxBitrateBps
        let b = WebRTCSession.bitrates(for: .lan, cap: maxBitrateBps)
        self.minBitrateBps = b.min
        self.startBitrateBps = b.start
        self.maxBitrateBps = b.max
        self.maxFramerate = maxFramerate
        self.configuredMaxFramerate = maxFramerate
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

    /// The size actually being captured, so a requested ceiling can be turned into a scale factor.
    public func setCaptureHeight(_ height: Int) {
        captureHeight = height
        applyEncodingParameters()
    }

    /// A `stream_settings` message from the controller (spec section 13.2). Caps are hints the host
    /// clamps to its own limits; nil restores automatic behaviour.
    public func applyStreamSettings(maxHeight: Int?, maxFps: Int?, preferLatency: Bool) {
        requestedMaxHeight = maxHeight
        requestedMaxFramerate = maxFps
        self.preferLatency = preferLatency
        applyEncodingParameters()
    }

    /// libwebrtc scales by a divisor rather than to a target, so turn the requested height into one.
    /// Never below 1: we do not upscale.
    static func scaleFactor(captureHeight: Int, maxHeight: Int?) -> Double {
        guard let maxHeight, maxHeight > 0, captureHeight > maxHeight else { return 1 }
        return Double(captureHeight) / Double(maxHeight)
    }

    private func applyEncodingParameters() {
        let params = videoSender.parameters
        let scale = WebRTCSession.scaleFactor(captureHeight: captureHeight, maxHeight: requestedMaxHeight)
        let fps = min(maxFramerate, requestedMaxFramerate ?? maxFramerate)
        for encoding in params.encodings {
            encoding.maxBitrateBps = NSNumber(value: maxBitrateBps)
            encoding.maxFramerate = NSNumber(value: fps)
            encoding.scaleResolutionDownBy = NSNumber(value: scale)
        }
        // A desktop is mostly text, and text survives a low frame rate far better than a low
        // resolution. An idle screen also sends almost nothing, which starves the bandwidth
        // estimate; under `balanced` the encoder answers that by shrinking the picture, so a still
        // desktop ends up permanently soft while using a few kbps. Keep the pixels, spend the
        // frames.
        // Asking for smooth motion means the opposite trade: let the picture soften to keep frames.
        params.degradationPreference = NSNumber(value: (preferLatency ? RTCDegradationPreference.balanced : .maintainResolution).rawValue)
        videoSender.parameters = params
        // A floor under the estimate, so resolution and quality decisions are not made from the
        // near-zero traffic of a still screen.
        pc.setBweMinBitrateBps(NSNumber(value: minBitrateBps), currentBitrateBps: NSNumber(value: startBitrateBps), maxBitrateBps: NSNumber(value: maxBitrateBps))
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
    /// Candidate type alone misclassifies a LAN peer whose candidate was learned as peer-reflexive,
    /// so a pair of private addresses also counts as LAN.
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
            completion(WebRTCSession.classifyPath(localType: localType, remoteType: remoteType, localAddress: localAddress, remoteAddress: remoteAddress))
        }
    }

    /// libwebrtc reports no address for a peer-reflexive remote candidate. A pair that was selected
    /// through one of our own host candidates on a private address was reached directly on that
    /// network, so it is LAN regardless of what the remote side looks like.
    static func classifyPath(localType: String, remoteType: String, localAddress: String, remoteAddress: String) -> String {
        if localType == "relay" || remoteType == "relay" { return "Relayed" }
        // Overlay addresses (Tailscale's 100.64/10) are private but may be relayed by the overlay
        // itself, so name them rather than calling them LAN.
        if isOverlayAddress(localAddress) || isOverlayAddress(remoteAddress) { return "Direct (Tailscale)" }
        if localType == "host" && remoteType == "host" { return "Direct (LAN)" }
        if localType == "host" && isPrivateAddress(localAddress) { return "Direct (LAN)" }
        if remoteType == "host" && isPrivateAddress(remoteAddress) { return "Direct (LAN)" }
        if isPrivateAddress(localAddress) && isPrivateAddress(remoteAddress) { return "Direct (LAN)" }
        return "Direct (Internet)"
    }

    /// Tailscale hands out IPv4 in the CGNAT range 100.64.0.0/10 and IPv6 under its ULA prefix
    /// fd7a:115c:a1e0::/48. Both are private, but calling them LAN hides that the overlay may be
    /// relaying through a DERP server, which is what a sudden half-second round trip means.
    static func isOverlayAddress(_ address: String) -> Bool {
        let a = address.lowercased()
        if a.hasPrefix("fd7a:115c:a1e0") { return true }
        let parts = a.split(separator: ".")
        guard parts.count == 4, parts[0] == "100", let second = Int(parts[1]) else { return false }
        return (64...127).contains(second)
    }

    /// RFC 1918, link-local, loopback, unique-local IPv6, and the CGNAT range Tailscale uses.
    static func isPrivateAddress(_ address: String) -> Bool {
        let a = address.lowercased()
        if a.hasPrefix("10.") || a.hasPrefix("192.168.") || a.hasPrefix("169.254.") || a.hasPrefix("127.") { return true }
        if a.hasPrefix("172.") {
            let parts = a.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        if a.hasPrefix("100.") {
            let parts = a.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (64...127).contains(second) { return true }
        }
        if a.hasPrefix("fc") || a.hasPrefix("fd") || a.hasPrefix("fe80") || a == "::1" { return true }
        return false
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
