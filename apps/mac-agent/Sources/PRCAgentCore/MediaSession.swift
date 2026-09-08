import CoreMedia
import Foundation
import PRCProtocol
import WebRTC

public enum MediaConnectionState: Sendable, Equatable {
    case connecting
    case connected(path: String)
    case disconnected
    case failed
    case closed
}

public protocol MediaSessionDelegate: AnyObject, Sendable {
    func media(didGenerateCandidate candidate: IceCandidatePayload)
    func media(didChangeState state: MediaConnectionState)
    func media(didOpenChannel label: ChannelLabel)
    func media(didReceive frame: DataChannelFrame, on label: ChannelLabel)
    func media(didRejectMessage error: DataChannelError)
}

/// The coordinator's view of screen capture plus WebRTC. Injected so tests can run without either.
public protocol MediaSession: AnyObject, Sendable {
    var delegate: MediaSessionDelegate? { get set }
    /// The path the controller declared in SESSION_REQUEST. Sets bitrate limits (spec section 15).
    func setPath(_ path: ConnectionPath)
    /// A `stream_settings` request from the controller.
    func applyStreamSettings(maxHeight: Int?, maxFps: Int?, preferLatency: Bool)
    /// Starts capture and prepares the peer connection. Returns the display being streamed.
    func start() async throws -> MediaDisplay
    func answer(offer: String) async throws -> String
    func add(candidate: IceCandidatePayload)
    func send(_ message: DataChannelMessage, ts: Int64)
    func stop() async
}

public typealias MediaSessionFactory = @Sendable () throws -> MediaSession

public enum MediaError: Error, Sendable {
    case screenRecordingDenied
}

/// ScreenCaptureKit into libwebrtc. One instance per session.
public final class LiveMediaSession: MediaSession, WebRTCSessionDelegate, @unchecked Sendable {
    public weak var delegate: MediaSessionDelegate?
    private let webrtc: WebRTCSession
    private var source: FrameSource?
    private var path: ConnectionPath = .lan
    private let config: AgentConfig
    private var announcedConnected = false

    public init(config: AgentConfig) throws {
        self.config = config
        webrtc = try WebRTCSession(iceServers: [], maxBitrateBps: config.maxBitrateBps, maxFramerate: config.maxFramerate)
        webrtc.delegate = self
    }

    public func setPath(_ path: ConnectionPath) {
        self.path = path
        webrtc.setPath(path)
    }

    public func applyStreamSettings(maxHeight: Int?, maxFps: Int?, preferLatency: Bool) {
        webrtc.applyStreamSettings(maxHeight: maxHeight, maxFps: maxFps, preferLatency: preferLatency)
    }

    public func start() async throws -> MediaDisplay {
        let webrtc = self.webrtc
        let handler: ScreenCapturer.FrameHandler = { pixelBuffer, time in
            webrtc.deliver(pixelBuffer: pixelBuffer, time: time)
        }
        let source: FrameSource
        if config.syntheticScreen {
            source = SyntheticFrameSource(frameHandler: handler)
        } else {
            guard Permissions.screenRecordingGranted else {
                Permissions.requestScreenRecording()
                throw MediaError.screenRecordingDenied
            }
            source = ScreenCapturer(frameHandler: handler)
        }
        self.source = source
        // Capturing at the rate we intend to send saves encode work and keeps pacing honest.
        let display = try await source.start(maxLongEdge: config.maxLongEdge, fps: WebRTCSession.framerate(for: path, cap: config.maxFramerate))
        webrtc.setCaptureHeight(Int(display.captureSize.height))
        return display
    }

    public func answer(offer: String) async throws -> String {
        try await webrtc.answer(offerSDP: offer)
    }

    public func add(candidate: IceCandidatePayload) {
        webrtc.add(candidate: candidate)
    }

    public func send(_ message: DataChannelMessage, ts: Int64) {
        webrtc.send(message, ts: ts)
    }

    public func stop() async {
        await source?.stop()
        source = nil
        webrtc.close()
    }

    // MARK: WebRTCSessionDelegate

    public func webrtc(_ session: WebRTCSession, didGenerateCandidate candidate: IceCandidatePayload) {
        delegate?.media(didGenerateCandidate: candidate)
    }

    public func webrtc(_ session: WebRTCSession, didChangeConnectionState state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            session.selectedPath { [weak self] path in
                self?.delegate?.media(didChangeState: .connected(path: path ?? "Direct"))
            }
        case .disconnected: delegate?.media(didChangeState: .disconnected)
        case .failed: delegate?.media(didChangeState: .failed)
        case .closed: delegate?.media(didChangeState: .closed)
        default: delegate?.media(didChangeState: .connecting)
        }
    }

    public func webrtc(_ session: WebRTCSession, didOpenChannel label: ChannelLabel) {
        delegate?.media(didOpenChannel: label)
    }

    public func webrtc(_ session: WebRTCSession, didReceive frame: DataChannelFrame, on label: ChannelLabel) {
        delegate?.media(didReceive: frame, on: label)
    }

    public func webrtc(_ session: WebRTCSession, didRejectMessage error: DataChannelError, on label: String) {
        delegate?.media(didRejectMessage: error)
    }
}
