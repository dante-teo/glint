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

Delete paths must remove both snapshot and journal files. Debounced saves must not resurrect a deleted conversation.

## Testing

Keep pure behavior covered close to the core:

- `AgentSessionReducerTests` for transcript merging, status transitions, stale tools, late notifications, pending interactions, usage/mode/config, and bounded retention.
- `AgentProjectFileServiceTests` for root containment, symlink handling, missing leaves, directory reads, line slicing, and write behavior.
- `AgentConversationStoreTests` for snapshot round-trip, journal replay, corrupted journal tolerance, snapshot/journal interaction, and delete safety.

Run these checks after changing the managed agent stack:

```bash
xcodegen generate
xcodebuild test -project Glint.xcodeproj -scheme Glint -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
```
