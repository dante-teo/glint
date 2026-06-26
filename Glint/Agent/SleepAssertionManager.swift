import Foundation
import IOKit
import IOKit.pwr_mgt

/// Thin wrapper around IOPMAssertion that prevents macOS idle system sleep.
///
/// `acquire()` creates a `kIOPMAssertionTypePreventUserIdleSystemSleep`
/// power assertion scoped to the Glint process; `release()` drops it.
/// Both calls are idempotent: double-acquire is a no-op, double-release
/// is safe. The assertion does NOT prevent lid-close sleep — only the
/// idle-timeout path — which is the correct behavior for keeping
/// long-running agents alive.
///
/// macOS automatically releases process-scoped assertions when the
/// process exits (including crashes and SIGKILL), so a leaked assertion
/// cannot outlive Glint. `deinit` also calls `release()` as a belt-and-
/// suspenders safety net.
final class SleepAssertionManager {
    private var assertionID: IOPMAssertionID?

    /// Whether an assertion is currently held.
    var isHolding: Bool { assertionID != nil }

    /// Create the sleep-prevention assertion if not already held.
    func acquire() {
        guard assertionID == nil else { return }
        var outID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Glint: agent is running" as CFString,
            &outID
        )
        if result == kIOReturnSuccess {
            assertionID = outID
        } else {
            NSLog("[glint] failed to create sleep assertion: \(result)")
        }
    }

    /// Release the sleep-prevention assertion if one is held.
    func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
    }

    deinit {
        release()
    }
}
