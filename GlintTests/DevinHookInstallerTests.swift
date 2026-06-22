import XCTest
@testable import Glint

final class DevinHookInstallerTests: XCTestCase {

    /// Verify the installer reports not-installed when no config exists.
    func testIsInstalledReturnsFalseByDefault() {
        XCTAssertFalse(DevinHookInstaller.isInstalled())
    }

    /// Verify presence detection checks for the ~/.config/devin directory
    /// or the `devin` command. We can't mock the filesystem here, so just
    /// ensure the function returns a Bool without crashing.
    func testIsAgentPresentReturnsBool() {
        let _ = DevinHookInstaller.isAgentPresent()
    }

    // MARK: - hookEvents regression guards

    /// StopFailure is unsupported by Devin CLI — it must never reappear.
    func testHookEventsExcludesStopFailure() {
        XCTAssertFalse(
            DevinHookInstaller.hookEvents.contains("StopFailure"),
            "StopFailure is not a valid Devin CLI hook event"
        )
    }

    /// PreCompact is unsupported by Devin CLI — only PostCompaction is valid.
    func testHookEventsExcludesPreCompact() {
        XCTAssertFalse(
            DevinHookInstaller.hookEvents.contains("PreCompact"),
            "PreCompact is not a valid Devin CLI hook event"
        )
    }

    /// Ensure only the documented Devin CLI lifecycle events are registered.
    func testHookEventsMatchDevinCLIDocs() {
        let expected: Set<String> = [
            "SessionStart", "SessionEnd", "UserPromptSubmit",
            "PreToolUse", "PostToolUse", "PermissionRequest",
            "PostCompaction", "Stop",
        ]
        XCTAssertEqual(
            Set(DevinHookInstaller.hookEvents), expected,
            "hookEvents should match exactly the events documented by Devin CLI"
        )
    }

    // MARK: - Stale hook cleanup

    /// A stale Glint-owned event (e.g. StopFailure from an old Glint
    /// version) is removed when it's no longer in the current event list.
    func testStaleGlintEntryIsRemoved() {
        let hooks: [String: Any] = [
            "Stop": [[
                "matcher": "",
                "hooks": [["type": "command", "command": "~/.glint/hooks/glint-report.sh Stop devin"]],
            ]],
            "StopFailure": [[
                "matcher": "",
                "hooks": [["type": "command", "command": "~/.glint/hooks/glint-report.sh StopFailure devin"]],
            ]],
        ]
        let current: Set<String> = ["Stop"]
        let (cleaned, changed) = DevinHookInstaller.hooksStrippingStaleEvents(hooks, currentEvents: current)
        XCTAssertTrue(changed)
        XCTAssertNotNil(cleaned["Stop"], "current event should be preserved")
        XCTAssertNil(cleaned["StopFailure"], "stale event should be removed")
    }

    /// User-authored hooks under a stale event key are kept; only glint
    /// entries are stripped.
    func testStaleCleanupPreservesUserHooks() {
        let userHook: [String: Any] = [
            "matcher": "exec",
            "hooks": [["type": "command", "command": "/usr/local/bin/my-logger.sh"]],
        ]
        let glintHook: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": "~/.glint/hooks/glint-report.sh StopFailure devin"]],
        ]
        let hooks: [String: Any] = [
            "StopFailure": [userHook, glintHook],
        ]
        let (cleaned, changed) = DevinHookInstaller.hooksStrippingStaleEvents(hooks, currentEvents: [])
        XCTAssertTrue(changed)
        // The user hook should remain under the event key.
        guard let remaining = cleaned["StopFailure"] as? [Any] else {
            XCTFail("StopFailure key should still exist (user hook present)")
            return
        }
        XCTAssertEqual(remaining.count, 1, "only the user hook should remain")
    }

    /// When no stale events exist, the helper reports no changes.
    func testNoStaleEventsReportsUnchanged() {
        let hooks: [String: Any] = [
            "Stop": [[
                "matcher": "",
                "hooks": [["type": "command", "command": "~/.glint/hooks/glint-report.sh Stop devin"]],
            ]],
        ]
        let (_, changed) = DevinHookInstaller.hooksStrippingStaleEvents(hooks, currentEvents: ["Stop"])
        XCTAssertFalse(changed)
    }

    /// Non-array event buckets (malformed JSON) are skipped without crash.
    func testMalformedBucketSkippedGracefully() {
        let hooks: [String: Any] = [
            "StopFailure": "not-an-array",
        ]
        let (cleaned, changed) = DevinHookInstaller.hooksStrippingStaleEvents(hooks, currentEvents: [])
        XCTAssertFalse(changed, "malformed bucket should be left alone")
        XCTAssertNotNil(cleaned["StopFailure"], "malformed bucket key should persist")
    }

    /// Entries that don't match the expected structure are preserved even
    /// when they sit under a stale event.
    func testNonDictEntryPreserved() {
        let hooks: [String: Any] = [
            "StopFailure": ["just-a-string"],
        ]
        let (cleaned, changed) = DevinHookInstaller.hooksStrippingStaleEvents(hooks, currentEvents: [])
        XCTAssertFalse(changed, "non-dict entries cannot be identified as ours")
        XCTAssertNotNil(cleaned["StopFailure"])
    }

    /// Multiple stale events are all cleaned in a single pass.
    func testMultipleStaleEventsCleanedAtOnce() {
        let glint: (String) -> [String: Any] = { event in [
            "matcher": "",
            "hooks": [["type": "command", "command": "~/.glint/hooks/glint-report.sh \(event) devin"]],
        ]}
        let hooks: [String: Any] = [
            "StopFailure": [glint("StopFailure")],
            "PreCompact": [glint("PreCompact")],
            "Stop": [glint("Stop")],
        ]
        let (cleaned, changed) = DevinHookInstaller.hooksStrippingStaleEvents(
            hooks, currentEvents: ["Stop"]
        )
        XCTAssertTrue(changed)
        XCTAssertNotNil(cleaned["Stop"])
        XCTAssertNil(cleaned["StopFailure"])
        XCTAssertNil(cleaned["PreCompact"])
    }
}
