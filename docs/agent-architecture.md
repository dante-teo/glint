# Agent Architecture

Glint has two agent paths:

- Terminal panes detect and decorate agents that are running inside Ghostty. This path owns terminal process polling, close confirmation, and terminal workspace controls.
- Managed ACP panes run a provider-backed session in Glint. This path is being refactored around a provider-neutral core with Devin as the first adapter.

Keep these paths separate. Changes in `Glint/Agent/Core` should not alter terminal-pane detection or terminal runtime control.

## Managed ACP Stack

The managed path is layered from stable domain state outward:

1. `AgentRuntimeAdapter` is the provider boundary. It starts the runtime, initializes ACP, creates or loads a session, sends prompts, cancels, closes, and sets modes.
2. `DevinACPAdapter` is the first provider adapter. It wraps `ACPClient` and preserves the existing ACP v1 wire shape, tolerant decoding, JSON-RPC request tracking, diagnostics, long prompt timeout, bounded close timeout, and process-exit failure propagation.
3. `AgentSessionController` owns async lifecycle and UI-facing commands. It should publish state and coordinate side effects, but it should not grow transcript merge logic, file validation rules, or permission option policy.
4. `AgentSessionReducer` is the pure state projector. It owns transcript chunk merging, tool upserts, status projection, stale tool marking, pending-interaction projection, usage/model/mode/config projection, and bounded transcript retention.
5. `AgentConversationStore` persists snapshots and an append-only event journal under `~/.glint/sessions/`.

`DevinSessionManager` remains as a compatibility typealias while the UI and tests migrate to provider-neutral names.

**Current state vs. target state:** the layering above (`AgentSessionController` delegating transcript/tool/status projection to `AgentSessionReducer`) is the target architecture, not yet the live one. Today `AgentSessionController` (in `Glint/Agent/DevinSessionManager.swift`) still owns its own independent copy of that projection logic — its own `indexForChunk`/`appendChunk`, `mergeToolCall`, `abandonUnfinishedToolCalls`, etc. — and is the only path real ACP traffic flows through; `AgentSessionReducer.reduce(_:event:)` is exercised only by `AgentSessionReducerTests` and by `AgentConversationStore.replayJournal`, not by the live controller. Until the controller is migrated to actually call into the reducer, treat the two as duplicate implementations of the same contract that must be changed together by hand — e.g. the "message chunk merging only continues the transcript's tail" fix (see `AGENTS.md`, "Devin ACP protocol integration") was applied to both `indexForChunk` copies with matching regression tests in `DevinSessionManagerTests` and `AgentSessionReducerTests`. Don't add reducer-only behavior assuming the controller already delegates to it.

**Session lifecycle:** `AgentSessionController.establishSession(client:projectPath:existingSessionID:)` is the one place a session gets started or resumed, called both lazily (right before the first/next `session/prompt`) and eagerly (`connectIfNeeded(projectPath:)`, driven by the composer appearing/getting a project path, so the UI's model/mode/reasoning pickers have real data before the user sends anything). It always prefers `session/load` over `session/new` when a persisted `sessionID` already exists from a prior app run, falling back to `session/new` only if the Agent no longer recognizes that id or there wasn't one. This matters for conversations restored via `AgentSessionController`'s own `loadPersistedConversation()`/`PersistedConversation` (see "Persistence" below — this is a separate mechanism from `AgentConversationStore`): without the `session/load` preference, resuming a workspace across app restarts would silently start a brand-new server-side session every time, abandoning the one the restored transcript claims to represent.

**Model and reasoning-level selection** goes through the ACP v1 `session/set_config_option` mechanism (`SessionConfigOption`/`SessionConfigOptionValue` in `ACPTypes.swift`, `ACPClient.setConfigOption`, `AgentSessionController.selectConfigOption(_:value:)`), not the older unstable `session/set_model`/`models`/`currentModel` fields. See `AGENTS.md`'s "Composer plan mode vs. ACP mode/model switching" for the full protocol shape and UI wiring.

## State Contracts

`AgentSessionSnapshot` is the UI read model. Views should consume this stable shape instead of interpreting raw ACP protocol details.

`AgentRuntimeEvent` is the canonical event stream for lifecycle, prompts, chunks, tool updates, permission and elicitation, usage, mode/config updates, diagnostics, turn completion, cancellation, and failure.

Reducer behavior that must remain deterministic:

- Late chunks or tool updates after a turn is no longer active may update transcript content, but must not make the pane busy again.
- When a turn completes, fails, or is cancelled, unfinished tool calls are marked stale with a reason.
- Tool updates may arrive before the initial create notification; the reducer must create an inspectable placeholder row.
- Status-only tool updates preserve existing title, kind, content, locations, raw input, and raw output.
- Pending permission and elicitation state is cleared on turn completion, cancellation, and failure.
- Transcript retention is bounded so a long-running session cannot grow memory without limit.

## Permissions

`AgentPermissionDecider` owns ACP permission option selection.

Required behavior:

- Approve chooses `allow_once` before `allow_always`, independent of offered array order.
- Deny chooses `reject_once` before `reject_always`, independent of offered array order.
- If no matching polarity exists, Glint responds with ACP `cancelled`.
- Cancel, stop, close, and quit must resume pending permission or elicitation continuations exactly once with a cancelled outcome.
- Auto-review reasoning must stay separate from original tool raw input.

Do not select an arbitrary first option as a fallback; that can silently invert a user's decision.

## Project File Access

`AgentProjectFileService` owns ACP file read/write safety. It validates paths against the selected project root before touching disk.

Required behavior:

- Reject absolute paths, path traversal, and symlink escapes outside the project root.
- For reads, require an existing non-directory file under the project root.
- For writes, validate existing symlink targets and the symlink-resolved parent directory for missing files.
- Keep line slicing deterministic for missing, negative, zero, or out-of-range line and limit values.

Terminal server requests should continue to return not implemented because Glint advertises `terminal = false`.

## Persistence

`AgentConversationStore` writes:

- snapshots: `<workspaceID>.json`
- journals: `<workspaceID>.events.ndjson`

Snapshot saves are atomic and clear the journal after the snapshot is written. This prevents replaying events that are already included in the snapshot. Journal replay skips corrupted lines so one bad event does not lose the whole conversation.

**This is the target persistence mechanism, not (yet) the live one** — same caveat as the reducer above. `AgentSessionController` currently persists via its own private `PersistedConversation` struct and `loadPersistedConversation()`/`scheduleSave()`, writing a single `<workspaceID>.json` blob (sessionID, models/currentModel, modes, configOptions, messages) to the same `~/.glint/sessions/` directory but in its own shape — not `AgentConversationStore`'s snapshot+journal format. `AgentConversationStore` is exercised only by `AgentConversationStoreTests`. Debounce timing (~250ms via `scheduleSave()`) and the "check `Task.isCancelled` after `try?`-wrapped `Task.sleep`" rule (see `AGENTS.md`, "Devin session teardown") apply to the live mechanism.

Delete paths must remove both snapshot and journal files. Debounced saves must not resurrect a deleted conversation.

## Testing

Keep pure behavior covered close to the core:

- `AgentSessionReducerTests` for transcript merging, status transitions, stale tools, late notifications, pending interactions, usage/mode/config, and bounded retention. Per the "current state vs. target state" note above, this covers the reducer's copy of the logic, not the live path.
- `AgentProjectFileServiceTests` for root containment, symlink handling, missing leaves, directory reads, line slicing, and write behavior.
- `AgentConversationStoreTests` for snapshot round-trip, journal replay, corrupted journal tolerance, snapshot/journal interaction, and delete safety. Also covers only the target persistence mechanism, not the live one.

`DevinSessionManagerTests` (`@MainActor`) is the live path's actual test suite — connect/resume (`session/load` vs `session/new`), the controller's own transcript-merge/tool-call copy, mode and config-option selection, permission/elicitation handling, notification-ordering/stuck-turn regressions, and the controller's own `PersistedConversation` round-trip. If you change `AgentSessionController`/`DevinSessionManager.swift` behavior, this is the suite that actually exercises it end to end via a fake `AgentRuntimeAdapter`.

Run these checks after changing the managed agent stack:

```bash
xcodegen generate
xcodebuild test -project Glint.xcodeproj -scheme Glint -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
