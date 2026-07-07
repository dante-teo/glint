import XCTest
@testable import Glint

final class OhMyPiHookInstallerTests: XCTestCase {

    /// Verify presence detection checks for the ~/.omp/agent directory or
    /// the `omp` command. We can't mock the filesystem/command lookup here,
    /// so just ensure the function returns a Bool without crashing.
    func testIsAgentPresentReturnsBool() {
        let _ = OhMyPiHookInstaller.isAgentPresent()
    }

    /// Regression guard: the hookEvents this hook reports to Glint's own
    /// status switch must match exactly what WorkspaceStore's PostToolUse/
    /// PreToolUse/etc. handling expects (see AgentHookInstaller.swift's
    /// OhMyPiHookInstaller.hookEvents definition).
    func testHookEventsMatchExpectedSet() {
        let expected: Set<String> = [
            "SessionStart", "SessionEnd", "UserPromptSubmit",
            "PreToolUse", "PostToolUse", "PermissionRequest",
            "PreCompact", "Stop", "StopFailure",
        ]
        XCTAssertEqual(Set(OhMyPiHookInstaller.hookEvents), expected)
    }

    // MARK: - Generated hook body registers the expected omp extension events

    func testPluginBodyRegistersSessionStart() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("session_start"))
    }

    func testPluginBodyRegistersSessionShutdown() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("session_shutdown"))
    }

    func testPluginBodyRegistersAgentStart() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("agent_start"))
    }

    func testPluginBodyRegistersToolCall() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("tool_call"))
    }

    func testPluginBodyRegistersToolResult() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("tool_result"))
    }

    func testPluginBodyRegistersToolApprovalRequested() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("tool_approval_requested"))
    }

    func testPluginBodyRegistersAutoCompactionStart() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("auto_compaction_start"))
    }

    func testPluginBodyRegistersAgentEnd() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("agent_end"))
    }

    func testPluginBodyRegistersAutoRetryEnd() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("auto_retry_end"))
    }

    /// The generated file must carry Glint's ownership marker so
    /// `isInstalled()` can detect it and Settings can offer to uninstall.
    func testPluginBodyContainsGlintMarker() {
        XCTAssertTrue(OhMyPiHookInstaller.pluginBody.contains("Glint"))
    }
}
