import Foundation
import IOKit.pwr_mgt

/// Keeps the display and system awake while a remote session is active (spec section 18).
public final class PowerAssertion: @unchecked Sendable {
    private var id: IOPMAssertionID = 0
    private var active = false
    private let lock = NSLock()

    public init() {}

    public func acquire(reason: String = "PRC remote session") {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        active = result == kIOReturnSuccess
        if !active { Log.agent.warning("power assertion failed: \(result)") }
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
    }

    deinit { release() }
}
