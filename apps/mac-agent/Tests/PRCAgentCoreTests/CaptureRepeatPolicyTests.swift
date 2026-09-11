import Foundation
import Testing
@testable import PRCAgentCore

/// The bug these exist to prevent: ScreenCaptureKit stops on display sleep, screen lock and
/// display reconfiguration, and the repeat timer used to go on re-sending the last frame for ever.
/// Both ends then read as healthy — frames keep arriving, so WebRTC's own freeze counters never
/// move — while the picture is frozen.
///
/// The trap on the other side is just as real: a motionless desktop produces no complete frames
/// either, so treating silence alone as death would restart capture every few seconds on an idle
/// Mac. Hence two signals, and the tests below pin both.
@Suite("Capture repeat policy")
struct CaptureRepeatPolicyTests {
    /// Capture started long ago unless a test says otherwise, so the settle window is out of the way.
    let policy = CaptureRepeatPolicy(intervalMs: 500, stallAfterMs: 3000, settleMs: 6000)
    let longAgo: Int64 = 0

    @Test func repeatsTheLastFrameWhileTheScreenIsMerelyStill() {
        // Nothing from ScreenCaptureKit for a while, but the screen is awake and unlocked: this is
        // an idle desktop, and restarting capture under it would be the wrong move.
        #expect(policy.decide(now: 10_000, lastSentMs: 9_400, lastActivityMs: 1_000, screenSuspect: false, startedAtMs: longAgo) == .repeatLast)
    }

    @Test func waitsWhenSomethingWentOutRecently() {
        #expect(policy.decide(now: 10_000, lastSentMs: 9_800, lastActivityMs: 9_000, screenSuspect: false, startedAtMs: longAgo) == .wait)
    }

    @Test func callsItStalledOnlyWhenTheScreenAgrees() {
        let quiet: Int64 = 6_999   // older than the deadline
        #expect(policy.decide(now: 10_000, lastSentMs: 9_400, lastActivityMs: quiet, screenSuspect: true, startedAtMs: longAgo) == .stalled)
        #expect(policy.decide(now: 10_000, lastSentMs: 9_400, lastActivityMs: quiet, screenSuspect: false, startedAtMs: longAgo) == .repeatLast)
    }

    /// A locked screen still gets the benefit of the doubt while buffers are arriving: an idle
    /// stream keeps delivering them, so it is alive whatever the lock state says.
    @Test func aLockedScreenWithALiveStreamIsNotStalled() {
        #expect(policy.decide(now: 10_000, lastSentMs: 9_400, lastActivityMs: 9_900, screenSuspect: true, startedAtMs: longAgo) == .repeatLast)
    }

    /// Staleness is measured from the last sign of life, so a repeat sent a moment ago must not
    /// postpone the verdict. This ordering is what made the old timer hide the failure.
    @Test func aFreshRepeatDoesNotHideAStall() {
        #expect(policy.decide(now: 10_000, lastSentMs: 9_999, lastActivityMs: 5_000, screenSuspect: true, startedAtMs: longAgo) == .stalled)
    }

    /// Earned by watching a real display wake: capture resumes, delivers a frame, falls quiet for a
    /// moment while CGDisplayIsAsleep still says asleep. Without this the agent restarted capture
    /// twice more and the controller's banner flickered between paused and active.
    @Test func aCaptureThatHasJustStartedIsGivenTimeToSettle() {
        let quiet: Int64 = 1_000       // no activity since the start
        // 4 s in: silent, screen still reads as asleep, but too young to be called dead.
        #expect(policy.decide(now: 5_000, lastSentMs: 4_400, lastActivityMs: quiet, screenSuspect: true, startedAtMs: 1_000) == .repeatLast)
        // 6 s in: the grace period is over.
        #expect(policy.decide(now: 7_000, lastSentMs: 6_400, lastActivityMs: quiet, screenSuspect: true, startedAtMs: 1_000) == .stalled)
    }

    @Test func theDeadlineIsInclusive() {
        #expect(policy.decide(now: 10_000, lastSentMs: 9_000, lastActivityMs: 7_000, screenSuspect: true, startedAtMs: longAgo) == .stalled)
        #expect(policy.decide(now: 10_000, lastSentMs: 9_000, lastActivityMs: 7_001, screenSuspect: true, startedAtMs: longAgo) == .repeatLast)
    }
}
