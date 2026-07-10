# Agent Activity and Event Integration

Glint treats agent status as terminal context, not as a transcript or prompt queue. Agent events identify a workspace pane and update transient UI state in the sidebar, tabs, Activity view, notifications, and Dock badge. Workspace persistence and terminal restoration remain independent of agent event state.

## Using Activity

The sidebar has two modes:

- **Workspaces** shows the saved workspace list and workspace search.
- **Activity** shows non-idle agent panes across every workspace.

Activity prioritizes approval requests, failures, active or compacting turns, and then unread completions. Rows include the agent, workspace, tab, pane, status, elapsed time, and any available detail. Select a row to route directly to its pane. Viewing a completed or failed pane acknowledges that state and clears its unread Activity and Dock indicators.

The detail button is keyboard- and click-accessible; hover is only an optional preview affordance elsewhere in the interface. Activity can also be opened from the command palette with **Show Agent Activity**. **Find in Sidebar** (`Command-Option-F`) always returns to Workspaces mode before focusing search.

## Local Socket Protocol

Agent integrations send one JSON object per connection to the Unix domain socket named by `GLINT_AGENT_SOCK`. Production and Debug builds use separate sockets under `~/.glint/run/` so their events cannot steal or cross-target each other. The pane identifier comes from `GLINT_PANE_ID` and has the form `<workspace-uuid>:<pane-sequence>`.

Glint continues to accept the original payload:

```json
{"pane":"<workspace-uuid>:1","hook":"UserPromptSubmit","agent":"codex-cli"}
```

Legacy `agent` labels remain permissive for compatibility. Known names are resolved by alias or substring; otherwise Glint retains the existing or process-derived pane kind when possible.

New integrations should send the version 1 envelope:

```json
{
  "version": 1,
  "eventID": "0190f28d-3ef5-7a6d-a6df-33ddad7b26d1",
  "pane": "<workspace-uuid>:1",
  "agent": "codex",
  "event": "turnStarted",
  "timestamp": "2026-07-10T00:00:00Z",
  "sessionID": "session-42",
  "detail": "Planning changes",
  "capabilities": ["focusPane"]
}
```

### Version 1 fields

| Field | Required | Contract |
| --- | --- | --- |
| `version` | Recommended | Omitted non-legacy payloads currently resolve to version 1. Unsupported versions are rejected. |
| `eventID` | Yes | A non-empty replay identifier. `event_id` is accepted as an alias. |
| `pane` | Yes | The exact `GLINT_PANE_ID`; malformed or unknown panes do not update UI state. |
| `agent` | Recommended | `claude`, `codex`, `opencode`, or `omp`/Oh My Pi aliases. Unknown explicit agents are rejected. Missing values currently default to Claude for compatibility. |
| `event` | Yes | A normalized lifecycle event or supported provider alias. |
| `timestamp` | Recommended | Unix seconds or ISO 8601. Receipt time is used when absent or invalid. |
| `sessionID` | No | Session identity. `session` and `session_id` are accepted aliases. |
| `detail` | No | Short actionable context. `message`, `tool`, and `tool_name` are accepted fallbacks. |
| `capabilities` | No | Any of `focusPane`, `interrupt`, `resume`, and `respondToApproval`. Capabilities describe available response channels; they do not silently grant permissions. |

The normalized lifecycle events are `sessionStarted`, `sessionEnded`, `turnStarted`, `toolStarted`, `toolCompleted`, `notification`, `permissionRequested`, `compactionStarted`, `turnCompleted`, `turnFailed`, and `interrupted`.

## Ordering, Replay, and Teardown

The reducer is deterministic and pane-scoped:

- The most recent 32 event IDs are retained to reject retries.
- Events older than the pane's last accepted timestamp are rejected.
- A late tool completion cannot hide a fresh permission request during its short recovery window.
- Session end clears transient pane status but retains replay tombstones, preventing a retried end event from clearing a newer session.
- Closing a pane or workspace clears its transient state and replay tombstones.
- Plain Escape and Return retain the existing optimistic recovery behavior for integrations that do not report interruption or approval resolution.

Transient session IDs, details, event health, capabilities, and replay data are deliberately excluded from `state.json`. Existing workspaces therefore need no migration.

## Verification

Protocol and reducer compatibility lives in `GlintTests/AgentEventPlatformTests.swift`. Activity projection, ordering, navigation, acknowledgement, and sidebar-mode behavior live in `GlintTests/AgentActivityPresentationTests.swift`. Run the complete suite before changing the event or Activity contracts:

```bash
xcodebuild test -project Glint.xcodeproj -scheme Glint -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
