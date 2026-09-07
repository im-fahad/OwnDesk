import AppKit
import CoreMedia
import CoreVideo
import Foundation

/// Anything that produces NV12 frames for the media pipeline. ScreenCaptureKit in production,
/// a generated pattern for headless testing.
public protocol FrameSource: AnyObject, Sendable {
    func start(maxLongEdge: Int, fps: Int) async throws -> MediaDisplay
    func stop() async
}

extension ScreenCapturer: FrameSource {}

/// TEST ONLY. A 720p moving pattern at up to 30 fps, so the encoder and WebRTC path can be
/// exercised end to end without Screen Recording permission. Never enabled by default.
public final class SyntheticFrameSource: FrameSource, @unchecked Sendable {
    public enum SyntheticError: Error { case pool }

    private let frameHandler: ScreenCapturer.FrameHandler
    private let queue = DispatchQueue(label: "prc.synthetic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var tick = 0
    private var width = 1280
    private var height = 720

    public init(frameHandler: @escaping ScreenCapturer.FrameHandler) {
        self.frameHandler = frameHandler
    }

    public func start(maxLongEdge: Int, fps: Int) async throws -> MediaDisplay {
        let scale = min(1, Double(maxLongEdge) / 1280)
        width = Int((1280 * scale) / 2) * 2
        height = Int((720 * scale) / 2) * 2
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw SyntheticError.pool }
        self.pool = pool

        let rate = max(1, min(fps, 30))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / rate))
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer

        let main = MediaDisplay.main()
        Log.media.notice("synthetic frame source started \(self.width, privacy: .public)x\(self.height, privacy: .public) @\(rate, privacy: .public)")
        return MediaDisplay(displayID: 0, pointBounds: main.pointBounds, scale: 1, pixelSize: CGSize(width: width, height: height), captureSize: CGSize(width: width, height: height))
    }

    public func stop() async {
        timer?.cancel()
        timer = nil
        pool = nil
    }

    private func emit() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let t = tick
        tick += 1
        let bar = (t * 8) % width
        if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let base = y.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let line = base + row * stride
                let rowShade = UInt8(truncatingIfNeeded: 40 + (row * 120) / max(height, 1))
                for col in 0..<width {
                    let inBar = abs(col - bar) < 24
                    let diagonal = ((col + row + t * 3) / 32) & 1 == 0
                    line[col] = inBar ? 235 : (diagonal ? rowShade : rowShade &+ 60)
                }
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let base = uv.assumingMemoryBound(to: UInt8.self)
            let cb = UInt8(truncatingIfNeeded: 128 + Int(40 * sin(Double(t) / 20)))
            let cr = UInt8(truncatingIfNeeded: 128 + Int(40 * cos(Double(t) / 20)))
            for row in 0..<(height / 2) {
                let line = base + row * stride
                var col = 0
                while col + 1 < width {
                    line[col] = cb
                    line[col + 1] = cr
                    col += 2
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        frameHandler(buffer, CMClockGetTime(CMClockGetHostTimeClock()))
    }
}
