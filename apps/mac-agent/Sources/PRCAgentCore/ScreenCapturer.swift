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

/// What the repeat timer should do on each tick.
///
/// A motionless desktop produces no *complete* ScreenCaptureKit frames, so re-sending the last one
/// keeps the encoder's cadence. But capture also stops for real — display sleep, screen lock, a
/// display reconfiguration — and repeating forever then turns a dead stream into a frozen picture
/// that both ends report as healthy: frames keep arriving, so WebRTC's own freeze counters never
/// move.
///
/// Silence alone cannot tell those apart, which is why `lastActivityMs` counts sample buffers of
/// every status — an idle stream still delivers them, a dead one delivers nothing — and why
/// declaring death also needs `screenSuspect`, the window server agreeing that the screen is
/// locked or the display asleep. Without that second opinion a merely still desktop would be
/// restarted every few seconds for ever.
///
/// The third rule, `settleMs`, was earned by watching a real display wake: capture comes back,
/// delivers a frame, goes quiet again for a moment, and `CGDisplayIsAsleep` still says asleep.
/// Measured on a Mac mini M4 that produced two extra restart cycles and made the controller's
/// banner flicker between paused and active. A capture that has only just started is therefore
/// given time to settle before anything is allowed to call it dead.
public struct CaptureRepeatPolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Something went out recently enough. Nothing to do.
        case wait
        /// Static screen. Re-send the last frame.
        case repeatLast
        /// No real frame for too long: capture is dead. Stop pretending it isn't.
        case stalled
    }

    public var intervalMs: Int64
    public var stallAfterMs: Int64
    public var settleMs: Int64

    public init(intervalMs: Int64 = ScreenCapturer.staticRepeatIntervalMs,
                stallAfterMs: Int64 = ScreenCapturer.stallAfterMs,
                settleMs: Int64 = ScreenCapturer.settleAfterStartMs) {
        self.intervalMs = intervalMs
        self.stallAfterMs = stallAfterMs
        self.settleMs = settleMs
    }

    /// `startedAtMs` is when the current capture began, not when the session did: every restart
    /// resets it.
    public func decide(now: Int64, lastSentMs: Int64, lastActivityMs: Int64, screenSuspect: Bool, startedAtMs: Int64) -> Decision {
        // Staleness is checked first: a repeat sent a moment ago must not hide the stall.
        if screenSuspect, now - lastActivityMs >= stallAfterMs, now - startedAtMs >= settleMs { return .stalled }
        if now - lastSentMs < intervalMs { return .wait }
        return .repeatLast
    }
}

/// Why capture is paused, asked of the window server rather than guessed from the error.
public enum ScreenState {
    public static var isLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        // The key is absent entirely while unlocked.
        return (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    public static var isDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    public static var pausedReason: CaptureState {
        if isLocked { return .pausedLocked }
        if isDisplayAsleep { return .pausedDisplayAsleep }
        return .pausedError
    }
}

/// ScreenCaptureKit stream of the main display, delivering NV12 pixel buffers (spec section 15).
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime) -> Void

    private let queue = DispatchQueue(label: "prc.capture", qos: .userInteractive)
    private let frameHandler: FrameHandler
    private var stream: SCStream?
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime, wallMs: Int64)?
    /// When ScreenCaptureKit last handed over a sample buffer of any status. An idle stream still
    /// delivers them; a dead one delivers nothing. This is the liveness signal, and it is
    /// deliberately not the same thing as the last usable frame.
    private var lastActivityMs: Int64 = 0
    private var repeatTimer: DispatchSourceTimer?
    private var stallReported = false
    private var startedAtMs: Int64 = 0
    private var startParams: (maxLongEdge: Int, fps: Int)?
    public private(set) var display: MediaDisplay?
    /// ScreenCaptureKit ended the stream itself.
    public var onStopped: (@Sendable (Error) -> Void)?
    /// The stream is nominally alive but has produced no new frame for `stallAfterMs`.
    public var onStalled: (@Sendable () -> Void)?

    /// Static screens produce no frames. Re-send the last one at this rate so the encoder keeps a cadence.
    public static let staticRepeatIntervalMs: Int64 = 500
    /// How long a screen may produce no new frame before we call the capture dead. Long enough that
    /// a genuinely idle desktop is never mistaken for one, short enough that a controller notices.
    public static let stallAfterMs: Int64 = 3000
    /// How long a freshly started capture is left alone before it may be called dead. Longer than
    /// `stallAfterMs`, so a display still finishing its wake is never restarted underneath itself.
    public static let settleAfterStartMs: Int64 = 6000

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
        startParams = (maxLongEdge, fps)
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
        queue.sync {
            lastFrame = nil
            startedAtMs = nowMs()
            lastActivityMs = startedAtMs
            stallReported = false
        }
        startRepeatTimer()
        Log.media.info("capture started \(Int(capture.width), privacy: .public)x\(Int(capture.height), privacy: .public) @\(fps, privacy: .public)")
        return display
    }

    /// Whether ScreenCaptureKit has produced at least one real frame since the last start.
    /// `start()` clears it, so a stream that opens at the lock screen and delivers nothing reads
    /// as false — which is the case a restart has to keep waiting through.
    public var hasDeliveredFrame: Bool { queue.sync { lastFrame != nil } }

    /// Stop and start again with the parameters of the last successful start. Throws whatever
    /// ScreenCaptureKit throws, so the caller can keep retrying while the screen is locked.
    public func restart() async throws -> MediaDisplay {
        guard let params = startParams else { throw CaptureError.noDisplay }
        await stop()
        return try await start(maxLongEdge: params.maxLongEdge, fps: params.fps)
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
        let policy = CaptureRepeatPolicy()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = nowMs()
            let suspect = ScreenState.isLocked || ScreenState.isDisplayAsleep
            // A session opened while the Mac is already locked never gets a first frame, so the
            // stall check cannot be behind a "have we sent anything yet" guard.
            let lastSent = self.lastFrame?.wallMs ?? self.lastActivityMs
            switch policy.decide(now: now, lastSentMs: lastSent, lastActivityMs: self.lastActivityMs,
                                 screenSuspect: suspect, startedAtMs: self.startedAtMs) {
            case .wait:
                return
            case .repeatLast:
                guard let last = self.lastFrame else { return }
                let time = CMClockGetTime(CMClockGetHostTimeClock())
                self.lastFrame = (last.buffer, time, now)
                self.frameHandler(last.buffer, time)
            case .stalled:
                guard !self.stallReported else { return }
                self.stallReported = true
                Log.media.error("capture stalled: nothing from ScreenCaptureKit for \(now - self.lastActivityMs, privacy: .public) ms")
                self.onStalled?()
            }
        }
        timer.resume()
        repeatTimer = timer
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int
        else { return }
        // Any status at all proves the stream is still running, which is what the stall detector
        // needs; only a complete one carries pixels worth sending.
        lastActivityMs = nowMs()
        if statusRaw == SCFrameStatus.stopped.rawValue {
            // A waking display emits one of these before it settles, so the same grace period applies.
            guard lastActivityMs - startedAtMs >= ScreenCapturer.settleAfterStartMs else { return }
            Log.media.notice("capture reported stopped")
            onStalled?()
            return
        }
        guard statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastFrame = (pixelBuffer, time, lastActivityMs)
        stallReported = false
        frameHandler(pixelBuffer, time)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.media.error("capture stopped: \(error.localizedDescription, privacy: .public)")
        onStopped?(error)
    }
}
