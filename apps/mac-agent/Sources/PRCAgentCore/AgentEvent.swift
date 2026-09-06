import Foundation
import PRCProtocol

/// What the UI or CLI shows. Never carries input contents, keys, or frames.
public enum AgentEvent: Sendable {
    case listening(port: UInt16, addresses: [String])
    case pairingOpened(QRPayload)
    case pairingRequest(deviceId: String, deviceName: String, deviceType: DeviceType, fingerprint: String)
    case pairingCompleted(deviceId: String, deviceName: String)
    case pairingFailed(String)
    case pairingClosed
    case sessionRequested(deviceId: String, deviceName: String)
    case sessionAuthenticated(deviceId: String, deviceName: String)
    case sessionConnected(deviceName: String, path: String)
    case sessionEnded(SessionEndReason)
    case rejected(deviceId: String, reason: SessionRejectReason)
    case remoteAccessChanged(Bool)
    case deviceRevoked(deviceId: String)
    case warning(String)
    case info(String)
}
