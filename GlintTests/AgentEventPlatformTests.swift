import XCTest
@testable import Glint

final class AgentEventPlatformTests: XCTestCase {
    private let pane = "00000000-0000-0000-0000-000000000001:1"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testLegacyAndVersionedEventsNormalizeToEquivalentLifecycleData() throws {
        let legacy = Data("{\"pane\":\"\(pane)\",\"hook\":\"UserPromptSubmit\",\"agent\":\"codex\"}\n".utf8)
        let versioned = Data("""
        {"version":1,"eventID":"evt-1","pane":"\(pane)","agent":"codex","event":"turn.started","timestamp":1700000000}
        """.utf8)

        let legacyEvent = try AgentEventDecoder.decode(legacy, receivedAt: now)
        let versionedEvent = try AgentEventDecoder.decode(versioned, receivedAt: now)

        XCTAssertEqual(legacyEvent.pane, versionedEvent.pane)
        XCTAssertEqual(legacyEvent.agent, versionedEvent.agent)
        XCTAssertEqual(legacyEvent.event, versionedEvent.event)
        XCTAssertEqual(legacyEvent.timestamp, versionedEvent.timestamp)
        XCTAssertNil(legacyEvent.eventID)
        XCTAssertEqual(versionedEvent.eventID, "evt-1")
    }

    func testVersionedEventDecodesSessionDetailAndCapabilities() throws {
        let data = Data("""
        {
          "version":1,
          "eventID":"evt-2",
          "pane":"\(pane)",
          "agent":"claude",
          "event":"permission.requested",
          "timestamp":"2023-11-14T22:13:20Z",
          "session":"session-7",
          "detail":"Allow git status?",
          "capabilities":["interrupt","resume","respondToApproval"]
        }
        """.utf8)

        let event = try AgentEventDecoder.decode(data, receivedAt: .distantPast)

        XCTAssertEqual(event.sessionID, "session-7")
        XCTAssertEqual(event.detail, "Allow git status?")
        XCTAssertEqual(event.capabilities, [.interrupt, .resume, .respondToApproval])
    }

    func testVersionedEventRequiresEventID() {
        let data = Data("{\"version\":1,\"pane\":\"\(pane)\",\"agent\":\"codex\",\"event\":\"turn.started\"}".utf8)

        XCTAssertThrowsError(try AgentEventDecoder.decode(data, receivedAt: now)) { error in
            XCTAssertEqual(error as? AgentEventDecodingError, .missingEventID)
        }
    }

    func testReducerRejectsDuplicateAndOutOfOrderEvents() {
        let started = AgentEvent(
            eventID: "same", pane: pane, agent: .codex, event: .turnStarted,
            timestamp: now
        )
        let first = AgentStateReducer.reduce(nil, event: started)
        XCTAssertEqual(first.state?.status, .thinking)

        let duplicate = AgentStateReducer.reduce(first.state, event: started)
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertEqual(duplicate.state, first.state)

        let stale = AgentEvent(
            eventID: "older", pane: pane, agent: .codex, event: .turnCompleted,
            timestamp: now.addingTimeInterval(-1)
        )
        let staleResult = AgentStateReducer.reduce(first.state, event: stale)
        XCTAssertEqual(staleResult.disposition, .stale)
        XCTAssertEqual(staleResult.state?.status, .thinking)
    }

    func testReducerPreservesFreshPermissionAgainstLateToolCompletion() {
        let waiting = PaneAgentState(
            kind: .claude,
            status: .needsPermission,
            updatedAt: now,
            lastEventAt: now
        )
        let postTool = AgentEvent(
            eventID: "post-tool", pane: pane, agent: .claude,
            event: .toolCompleted, timestamp: now.addingTimeInterval(1)
        )

        let result = AgentStateReducer.reduce(waiting, event: postTool)

        XCTAssertEqual(result.disposition, .protectedPermission)
        XCTAssertEqual(result.state?.status, .needsPermission)
    }

    func testReducerClearsTransientStateOnSessionExit() {
        let state = PaneAgentState(
            kind: .opencode,
            status: .thinking,
            updatedAt: now,
            sessionID: "abc",
            capabilities: [.interrupt]
        )
        let event = AgentEvent(
            eventID: "exit", pane: pane, agent: .opencode,
            event: .sessionEnded, timestamp: now.addingTimeInterval(1)
        )

        let result = AgentStateReducer.reduce(state, event: event)

        XCTAssertEqual(result.disposition, .applied)
        XCTAssertNil(result.state)
    }

    func testAgentSpecificAliasesNormalize() throws {
        let fixtures: [(String, AgentLifecycleEvent)] = [
            ("agent/analysis", .turnStarted),
            ("tool.execute.before", .toolStarted),
            ("permission_asked", .permissionRequested),
            ("context_compaction", .compactionStarted),
            ("turn.failed", .turnFailed),
        ]

        for (raw, expected) in fixtures {
            let data = Data("{\"version\":1,\"eventID\":\"\(raw)\",\"pane\":\"\(pane)\",\"agent\":\"opencode\",\"event\":\"\(raw)\",\"timestamp\":1700000000}".utf8)
            XCTAssertEqual(try AgentEventDecoder.decode(data, receivedAt: now).event, expected, raw)
        }
    }

    func testLegacyAgentLabelsRetainSubstringCompatibility() throws {
        let data = Data("{\"pane\":\"\(pane)\",\"hook\":\"UserPromptSubmit\",\"agent\":\"codex-cli\"}".utf8)

        let event = try AgentEventDecoder.decode(data, receivedAt: now)

        XCTAssertEqual(event.agent, .codex)
        XCTAssertEqual(event.event, .turnStarted)
    }

    func testLegacyEventRejectsExplicitUnknownAgent() {
        let data = Data("{\"pane\":\"\(pane)\",\"hook\":\"UserPromptSubmit\",\"agent\":\"devin\"}".utf8)

        XCTAssertThrowsError(try AgentEventDecoder.decode(data, receivedAt: now)) { error in
            XCTAssertEqual(error as? AgentEventDecodingError, .unknownAgent("devin"))
        }
    }

    func testLegacyEventWithoutAgentFallsBackToClaude() throws {
        let data = Data("{\"pane\":\"\(pane)\",\"hook\":\"UserPromptSubmit\"}".utf8)

        XCTAssertEqual(try AgentEventDecoder.decode(data, receivedAt: now).agent, .claude)
    }

    func testSessionEndReplayIDSurvivesStateTeardown() {
        let oldState = PaneAgentState(
            kind: .codex,
            status: .thinking,
            updatedAt: now,
            sessionID: "old"
        )
        let endedEvent = AgentEvent(
            eventID: "end-old",
            pane: pane,
            agent: .codex,
            event: .sessionEnded,
            timestamp: now
        )
        let ended = AgentStateReducer.reduce(oldState, event: endedEvent)
        XCTAssertNil(ended.state)
        XCTAssertEqual(ended.replayEventIDs, ["end-old"])

        let restartedEvent = AgentEvent(
            eventID: "start-new",
            pane: pane,
            agent: .codex,
            event: .sessionStarted,
            timestamp: now.addingTimeInterval(1),
            sessionID: "new"
        )
        let restarted = AgentStateReducer.reduce(
            nil,
            event: restartedEvent,
            replayEventIDs: ended.replayEventIDs
        )
        let retriedEnd = AgentEvent(
            eventID: "end-old",
            pane: pane,
            agent: .codex,
            event: .sessionEnded,
            timestamp: now.addingTimeInterval(2)
        )
        let replay = AgentStateReducer.reduce(
            restarted.state,
            event: retriedEnd,
            replayEventIDs: restarted.replayEventIDs
        )

        XCTAssertEqual(replay.disposition, .duplicate)
        XCTAssertEqual(replay.state?.sessionID, "new")
    }
}
