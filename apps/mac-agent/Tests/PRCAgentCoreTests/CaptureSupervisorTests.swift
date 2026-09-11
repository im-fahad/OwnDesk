import CoreGraphics
import Foundation
import PRCProtocol
import Testing
@testable import PRCAgentCore

/// A capturer that can be told to fail, to start but deliver nothing (what the lock screen does),
/// or to work.
final class FakeSource: RestartableSource, @unchecked Sendable {
    enum Behaviour: Sendable { case fails, startsButSilent, works }

    private let lock = NSLock()
    private var behaviour: Behaviour
    private(set) var restarts = 0
    var display = MediaDisplay(displayID: 1, pointBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                               scale: 2, pixelSize: CGSize(width: 2880, height: 1800), captureSize: CGSize(width: 1920, height: 1200))

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func set(_ b: Behaviour) { lock.lock(); behaviour = b; lock.unlock() }

    struct Failed: Error {}

    func start(maxLongEdge: Int, fps: Int) async throws -> MediaDisplay { display }
    func stop() async {}

    /// Locking lives in a synchronous helper: NSLock from an async context is an error in Swift 6.
    private func noteRestart() -> Behaviour {
        lock.lock(); defer { lock.unlock() }
        restarts += 1
        return behaviour
    }

    func restart() async throws -> MediaDisplay {
        if noteRestart() == .fails { throw Failed() }
        return display
    }

    var hasDeliveredFrame: Bool {
        lock.lock(); defer { lock.unlock() }
        return behaviour == .works
    }
}

@Suite("Capture supervisor")
struct CaptureSupervisorTests {
    /// Fast enough that the tests are not a sleep, slow enough to exercise the polling.
    let quick = CaptureSupervisor.Timing(eagerAttempts: 100, eagerDelayMs: 10, patientAttempts: 200,
                                         patientDelayMs: 10, longDelayMs: 10, frameWaitMs: 40, pollMs: 5,
                                         reportAfterMs: 0)
    /// Same, but with a reporting debounce long enough to swallow a short outage.
    let debounced = CaptureSupervisor.Timing(eagerAttempts: 100, eagerDelayMs: 10, patientAttempts: 200,
                                             patientDelayMs: 10, longDelayMs: 10, frameWaitMs: 40, pollMs: 5,
                                             reportAfterMs: 3000)

    /// Collects what the controller would be told.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(CaptureState, String?, MediaDisplay?)] = []
        func add(_ s: CaptureState, _ d: String?, _ m: MediaDisplay?) { lock.lock(); items.append((s, d, m)); lock.unlock() }
        var states: [CaptureState] { lock.lock(); defer { lock.unlock() }; return items.map(\.0) }
        var lastDisplay: MediaDisplay? { lock.lock(); defer { lock.unlock() }; return items.last?.2 }
    }

    func waitUntil(_ timeoutMs: Int = 3000, _ condition: @escaping () -> Bool) async -> Bool {
        var waited = 0
        while waited < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5 * 1_000_000)
            waited += 5
        }
        return condition()
    }

    @Test func reportsThePauseAndThenTheRecovery() async {
        let source = FakeSource(.works)
        let reports = Reports()
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedDisplayAsleep }) { s, d, m in
            reports.add(s, d, m)
        }
        supervisor.captureFailed("display slept")
        #expect(await waitUntil { reports.states.count == 2 })
        #expect(reports.states == [.pausedDisplayAsleep, .active])
        // The restarted capture's display goes out too: it may be a different size.
        #expect(reports.lastDisplay?.captureSize == CGSize(width: 1920, height: 1200))
        supervisor.cancel()
    }

    /// The reported reason is whatever the window server says at the time, not a guess from the error.
    @Test func aLockedScreenIsReportedAsLocked() async {
        let source = FakeSource(.fails)
        let reports = Reports()
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedLocked }) { s, d, m in
            reports.add(s, d, m)
        }
        supervisor.captureFailed("stream stopped")
        #expect(await waitUntil { !reports.states.isEmpty })
        #expect(reports.states.first == .pausedLocked)
        supervisor.cancel()
    }

    /// The trap this pins: at the lock screen ScreenCaptureKit opens a stream that never produces
    /// a frame. Calling that "recovered" would put the frozen picture back with no explanation.
    @Test func aStreamThatStartsButDeliversNothingIsNotRecovery() async {
        let source = FakeSource(.startsButSilent)
        let reports = Reports()
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedLocked }) { s, d, m in
            reports.add(s, d, m)
        }
        supervisor.captureFailed("locked")
        #expect(await waitUntil { source.restarts >= 2 })
        #expect(reports.states == [.pausedLocked], "must not claim recovery without a frame")
        #expect(supervisor.isRecovering)

        // Unlocking is what actually ends it.
        source.set(.works)
        #expect(await waitUntil { reports.states.count == 2 })
        #expect(reports.states == [.pausedLocked, .active])
        supervisor.cancel()
    }

    @Test func keepsRetryingWhileRestartsKeepFailing() async {
        let source = FakeSource(.fails)
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedError }) { _, _, _ in }
        supervisor.captureFailed("boom")
        #expect(await waitUntil { source.restarts >= 3 })
        source.set(.works)
        #expect(await waitUntil { !supervisor.isRecovering })
        supervisor.cancel()
    }

    @Test func onlyOneRecoveryRunsAtATime() async {
        let source = FakeSource(.fails)
        let reports = Reports()
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedError }) { s, d, m in
            reports.add(s, d, m)
        }
        for _ in 0..<5 { supervisor.captureFailed("boom") }
        #expect(await waitUntil { source.restarts >= 2 })
        #expect(reports.states.count == 1, "the controller hears about the pause once, not five times")
        supervisor.cancel()
    }

    /// Waking with a healthy capture must not restart it: that would be a self-inflicted glitch.
    @Test func aKickWithFramesFlowingChangesNothing() async {
        let source = FakeSource(.works)
        let reports = Reports()
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedError }) { s, d, m in
            reports.add(s, d, m)
        }
        supervisor.kick(reason: "woke")
        _ = await waitUntil(100) { false }
        #expect(reports.states.isEmpty)
        #expect(source.restarts == 0)
        #expect(!supervisor.isRecovering)
    }

    /// But waking with a silent capture starts recovery even though ScreenCaptureKit never said so.
    @Test func aKickWithNoFramesStartsRecovery() async {
        let source = FakeSource(.startsButSilent)
        let reports = Reports()
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedError }) { s, d, m in
            reports.add(s, d, m)
        }
        supervisor.kick(reason: "woke")
        #expect(await waitUntil { source.restarts >= 1 })
        #expect(reports.states == [.pausedError])
        supervisor.cancel()
    }

    /// Earned on a real display wake: capture came back, then ScreenCaptureKit stopped it again
    /// within a second while the display list settled. Restarting through that is right;
    /// announcing it flickered the controller's banner between paused and active three times.
    @Test func anOutageTooShortToSeeIsNeverAnnounced() async {
        let source = FakeSource(.works)
        let reports = Reports()
        let supervisor = CaptureSupervisor(source: source, timing: debounced, pausedReason: { .pausedError }) { s, d, m in
            reports.add(s, d, m)
        }
        supervisor.captureFailed("Failed to find any displays or windows to capture")
        #expect(await waitUntil { !supervisor.isRecovering })
        // Recovery still reports active, carrying the display, but no pause was ever announced.
        #expect(reports.states == [.active])
        #expect(reports.lastDisplay != nil, "the encoder still needs the restarted display")
        supervisor.cancel()
    }

    /// An outage that lasts is announced, with the reason read at that moment.
    @Test func anOutageThatLastsIsAnnounced() async {
        let source = FakeSource(.fails)
        let reports = Reports()
        let timing = CaptureSupervisor.Timing(eagerAttempts: 100, eagerDelayMs: 10, patientAttempts: 200,
                                              patientDelayMs: 10, longDelayMs: 10, frameWaitMs: 40, pollMs: 5,
                                              reportAfterMs: 60)
        let supervisor = CaptureSupervisor(source: source, timing: timing, pausedReason: { .pausedLocked }) { s, d, m in
            reports.add(s, d, m)
        }
        supervisor.captureFailed("stream stopped")
        #expect(await waitUntil { reports.states == [.pausedLocked] })
        source.set(.works)
        #expect(await waitUntil { reports.states == [.pausedLocked, .active] })
        supervisor.cancel()
    }

    @Test func cancelStopsTheLoop() async {
        let source = FakeSource(.fails)
        let supervisor = CaptureSupervisor(source: source, timing: quick, pausedReason: { .pausedError }) { _, _, _ in }
        supervisor.captureFailed("boom")
        #expect(await waitUntil { source.restarts >= 1 })
        supervisor.cancel()
        #expect(await waitUntil { !supervisor.isRecovering })
        let after = source.restarts
        _ = await waitUntil(80) { false }
        #expect(source.restarts <= after + 1, "no further restarts after cancel")
    }
}
