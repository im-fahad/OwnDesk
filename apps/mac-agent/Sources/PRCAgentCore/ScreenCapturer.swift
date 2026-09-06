import AppKit
import CoreMedia
import Foundation
import PRCProtocol
import ScreenCaptureKit

public enum CaptureError: Error, Sendable {
    case noDisplay
    case permissionDenied
}

/// The display being streamed, in the units each consumer needs.
public struct MediaDisplay: Sendable {
    public var displayID: CGDirectDisplayID
    /// Global point coordinates, top-left origin, the space CGEvent uses.
    public var pointBounds: CGRect
    public var scale: CGFloat
    public var pixelSize: CGSize
    public var captureSize: CGSize

    public var info: DisplayInfo {
        DisplayInfo(display_id: String(displayID), width_px: Int(pixelSize.width), height_px: Int(pixelSize.height), scale: Double(scale))
    }

    /// The main display, for coordinate mapping when nothing is being captured.
    public static func main() -> MediaDisplay {
        let id = CGMainDisplayID()
        let bounds = CGDisplayBounds(id)
        let scale = ScreenCapturer.backingScale(for: id)
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return MediaDisplay(displayID: id, pointBounds: bounds, scale: scale, pixelSize: pixels, captureSize: pixels)
    }
}

/// ScreenCaptureKit stream of the main display, delivering NV12 pixel buffers (spec section 15).
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime) -> Void

    private let queue = DispatchQueue(label: "prc.capture", qos: .userInteractive)
    private let frameHandler: FrameHandler
    private var stream: SCStream?
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime, wallMs: Int64)?
    private var repeatTimer: DispatchSourceTimer?
    public private(set) var display: MediaDisplay?
    public var onStopped: (@Sendable (Error) -> Void)?

    /// Static screens produce no frames. Re-send the last one at this rate so the encoder keeps a cadence.
    public static let staticRepeatIntervalMs: Int64 = 500

    public init(frameHandler: @escaping FrameHandler) {
        self.frameHandler = frameHandler
    }

    static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.backingScaleFactor ?? 1
    }

    public func start(maxLongEdge: Int, fps: Int) async throws -> MediaDisplay {
        guard Permissions.screenRecordingGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let scDisplay = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let bounds = CGDisplayBounds(scDisplay.displayID)
        let scale = ScreenCapturer.backingScale(for: scDisplay.displayID)
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let factor = min(1, CGFloat(maxLongEdge) / max(pixels.width, pixels.height))
        // Even dimensions keep the 4:2:0 encoder happy.
        let capture = CGSize(width: floor(pixels.width * factor / 2) * 2, height: floor(pixels.height * factor / 2) * 2)

        let config = SCStreamConfiguration()
        config.width = Int(capture.width)
        config.height = Int(capture.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 3
        config.capturesAudio = false

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        let display = MediaDisplay(displayID: scDisplay.displayID, pointBounds: bounds, scale: scale, pixelSize: pixels, captureSize: capture)
        self.display = display
        startRepeatTimer()
        Log.media.info("capture started \(Int(capture.width), privacy: .public)x\(Int(capture.height), privacy: .public) @\(fps, privacy: .public)")
        return display
    }

    public func stop() async {
        repeatTimer?.cancel()
        repeatTimer = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        queue.sync { lastFrame = nil }
    }

    private func startRepeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(ScreenCapturer.staticRepeatIntervalMs)), repeating: .milliseconds(Int(ScreenCapturer.staticRepeatIntervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self, let last = self.lastFrame else { return }
            let now = nowMs()
            guard now - last.wallMs >= ScreenCapturer.staticRepeatIntervalMs else { return }
            let time = CMClockGetTime(CMClockGetHostTimeClock())
            self.lastFrame = (last.buffer, time, now)
            self.frameHandler(last.buffer, time)
        }
        timer.resume()
        repeatTimer = timer
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastFrame = (pixelBuffer, time, nowMs())
        frameHandler(pixelBuffer, time)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.media.error("capture stopped: \(error.localizedDescription, privacy: .public)")
        onStopped?(error)
    }
}
