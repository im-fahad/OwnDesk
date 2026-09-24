import ApplicationServices
import CoreGraphics
import Foundation

/// The two TCC permissions the agent needs. Both are tied to the code-signing identity of the
/// running process; a bare `swift run` binary inherits the grant given to the terminal app.
public enum Permissions {
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once. Returns the current state, which may still be false until the user acts.
    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
