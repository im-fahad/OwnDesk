import Foundation
import PRCProtocol

/// A frame source that can be brought back after it stops.
public protocol RestartableSource: FrameSource {
    /// Stop and start again with the parameters of the last successful start.
    func restart() async throws -> MediaDisplay
    /// Whether a usable frame has arrived since that start.
    var hasDeliveredFrame: Bool { get }
}

extension ScreenCapturer: RestartableSource {}

/// Brings screen capture back after it stops, and says what the controller should be told while it
/// is gone.
///
/// ScreenCaptureKit stops on display sleep, screen lock and display reconfiguration, and does not
/// restart itself. Nothing downstream notices: the encoder simply stops being fed, so the
/// controller keeps a healthy connection showing a frozen desktop, with input still working. That
/// combination — live session, dead picture — is the bug this exists to end.
///
/// Split out of `LiveMediaSession` so the retry rules can be tested without ScreenCaptureKit.
public final class CaptureSupervisor: @unchecked Sendable {
    /// How hard to try, and for how long. Eager at first because most interruptions are brief;
    /// patient after that because a locked Mac can sit there all night and asking the window
    /// server twice a second for hours would be its own bug.
    public struct Timing: Sendable {
        public var eagerAttempts: Int
        public var eagerDelayMs: Int
        public var patientAttempts: Int
        public var patientDelayMs: Int
        public var longDelayMs: Int
        /// How long to wait for a frame after a restart reports success.
        public var frameWaitMs: Int
        public var pollMs: Int
        /// How long an outage must last before the controller hears about it. Measured on a real
        /// display wake: ScreenCaptureKit resumes, then stops again within a second with "Failed to
        /// find any displays or windows to capture" while the display list settles. Restarting
        /// through that is right; announcing each blip flickered the controller's banner between
        /// paused and active three times in four seconds.
        public var reportAfterMs: Int

        public init(eagerAttempts: Int = 10, eagerDelayMs: Int = 500, patientAttempts: Int = 30,
                    patientDelayMs: Int = 2000, longDelayMs: Int = 5000, frameWaitMs: Int = 2000,
                    pollMs: Int = 100, reportAfterMs: Int = 1500) {
            self.eagerAttempts = eagerAttempts; self.eagerDelayMs = eagerDelayMs
            self.patientAttempts = patientAttempts; self.patientDelayMs = patientDelayMs
            self.longDelayMs = longDelayMs; self.frameWaitMs = frameWaitMs; self.pollMs = pollMs
            self.reportAfterMs = reportAfterMs
        }
    }

    public typealias Change = @Sendable (CaptureState, String?, MediaDisplay?) -> Void

    private let source: any RestartableSource
    private let timing: Timing
    private let pausedReason: @Sendable () -> CaptureState
    private let onChange: Change
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var kickRequested = false
    private var pendingDetail: String?
    /// Attempts made since the current interruption began. Read by tests.
    public private(set) var attempts = 0

    public init(source: any RestartableSource,
                timing: Timing = Timing(),
                pausedReason: @escaping @Sendable () -> CaptureState = { ScreenState.pausedReason },
                onChange: @escaping Change) {
        self.source = source
        self.timing = timing
        self.pausedReason = pausedReason
        self.onChange = onChange
    }

    public var isRecovering: Bool { lock.lock(); defer { lock.unlock() }; return task != nil }

    /// Capture stopped. Starts recovery unless it is already under way. The controller is told
    /// only if the outage outlasts `reportAfterMs`, so a blip nobody could see stays invisible.
    public func captureFailed(_ detail: String) {
        lock.lock(); pendingDetail = detail; lock.unlock()
        guard beginIfIdle() else { return }
        Log.media.notice("capture stopped, recovering: \(detail, privacy: .public)")
    }

    /// Unlock and wake are the moments recovery matters most, so they cut the backoff short
    /// instead of leaving the owner watching a stale desktop for another few seconds. If nothing
    /// is recovering, this decides whether anything needs to.
    public func kick(reason: String) {
        lock.lock()
        let running = task != nil
        kickRequested = true
        lock.unlock()
        guard !running else { return }
        // Capture can die without ScreenCaptureKit saying so. Only act if it really is silent.
        if !source.hasDeliveredFrame { captureFailed(reason) }
    }

    public func cancel() {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }

    private func beginIfIdle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return false }
        attempts = 0
        task = Task { [weak self] in await self?.loop() }
        return true
    }

    private func finish() { lock.lock(); task = nil; lock.unlock() }

    private func takeKick() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { kickRequested = false }
        return kickRequested
    }

    private func takeDetail() -> String? {
        lock.lock(); defer { lock.unlock() }
        return pendingDetail
    }

    private func bump() -> Int { lock.lock(); defer { lock.unlock() }; attempts += 1; return attempts }

    private func loop() async {
        let began = Date().timeIntervalSince1970
        var reported = false
        func elapsedMs() -> Int { Int((Date().timeIntervalSince1970 - began) * 1000) }

        while !Task.isCancelled {
            let attempt = bump()
            await waitBeforeRetry(attempt: attempt)
            guard !Task.isCancelled else { break }
            if !reported, elapsedMs() >= timing.reportAfterMs {
                reported = true
                let state = pausedReason()
                let detail = takeDetail()
                Log.media.notice("capture paused (\(state.rawValue, privacy: .public)): \(detail ?? "", privacy: .public)")
                onChange(state, detail, nil)
            }
            do {
                let display = try await source.restart()
                // Starting is not enough. At the lock screen ScreenCaptureKit will happily open a
                // stream that never produces anything, and reporting that as recovered would put
                // the frozen picture back with no explanation.
                guard await frameArrives() else {
                    if attempt % 20 == 0 { Log.media.notice("capture restarted but produces no frames (attempt \(attempt, privacy: .public))") }
                    continue
                }
                finish()
                Log.media.info("capture resumed after \(attempt, privacy: .public) attempt(s), \(elapsedMs(), privacy: .public) ms")
                // Always handed up, reported or not: a restarted capture can be a different size,
                // and the encoder needs to know even when the outage was too short to announce.
                onChange(.active, nil, display)
                return
            } catch {
                if attempt % 20 == 0 {
                    Log.media.notice("capture restart failing (attempt \(attempt, privacy: .public)): \(String(describing: error), privacy: .public)")
                }
            }
        }
        finish()
    }

    private func waitBeforeRetry(attempt: Int) async {
        let delayMs = attempt <= timing.eagerAttempts ? timing.eagerDelayMs
            : (attempt <= timing.patientAttempts ? timing.patientDelayMs : timing.longDelayMs)
        var waited = 0
        while waited < delayMs, !Task.isCancelled {
            await sleepPoll()
            waited += timing.pollMs
            if takeKick() { return }
        }
    }

    private func frameArrives() async -> Bool {
        var waited = 0
        while waited < timing.frameWaitMs, !Task.isCancelled {
            if source.hasDeliveredFrame { return true }
            await sleepPoll()
            waited += timing.pollMs
        }
        return source.hasDeliveredFrame
    }

    private func sleepPoll() async {
        try? await Task.sleep(nanoseconds: UInt64(timing.pollMs) * 1_000_000)
    }
}
