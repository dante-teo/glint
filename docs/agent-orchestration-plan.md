# Agent Orchestration Control Center

Transform Glint from a terminal-only app into an agent orchestration control center, starting with Devin CLI integration via ACP (Agent Client Protocol).

## Key UX Behaviors

1. **New Workspace picker:** Cmd+N shows a popover with two options: "Terminal" (existing) and "Devin Agent". Auto-expands sidebar if collapsed.
2. **Inline project selection:** Picking "Devin Agent" creates a draft agent pane immediately. The project is chosen from a Codex-style dropdown under the message box; its "Choose Folder..." item is the only path that opens NSOpenPanel.
3. **Sidebar visibility gating:** Agent workspaces are invisible in the sidebar until the user sends their first message (`committed` flag). Prevents empty/abandoned sessions from cluttering the sidebar.
4. **Uncommitted auto-cleanup:** If the user switches away before sending a first message, the uncommitted agent workspace is silently deleted.
5. **Archive vs Delete:** Agent sessions support "Archive" (preserves conversation history in `~/.glint/sessions/`) and "Delete" (destroys everything). Terminals just close.

## Reference Material

- **Synara** (https://github.com/Emanuele-web04/synara): Multi-provider agent orchestration web app. Its `packages/effect-acp` implements ACP v0.11.3 in TypeScript/Effect. Use as the definitive reference for ACP wire format and session lifecycle.
- **ACP spec:** https://agentclientprotocol.com/protocol/schema
- **Devin CLI `acp` subcommand:** `devin acp` runs as an ACP server over stdio (JSON-RPC, newline-delimited). Meant for editor/IDE integration. Reads credentials from `devin auth login` or `WINDSURF_API_KEY`.

## Architecture

```
User clicks "Devin Agent" in popover
         |
         v
   WorkspaceStore.addAgentWorkspace(provider: .devin)
   - creates Workspace with kind=.agent, committed=false
   - projectPath is optional; draft name falls back to "Devin Agent"
   - selects it (pane renders), but sidebar card is hidden
         |
         v
   AgentPaneView renders (empty state + composer + project dropdown)
         |
         v
   User picks a project from recent valid agent projects, inherited cwd,
   or "Choose Folder..." (NSOpenPanel)
         |
         v
   User types first message, hits send
   - validate selected folder still exists and is a directory
   - store.setAgentProjectPath() -> standardized absolute path + auto-name
   - store.commitAgentWorkspace() -> committed=true -> sidebar card appears
   - DevinSessionManager.sendFirstPrompt(text:projectPath:)
     - spawns `devin acp` subprocess
     - ACPClient: initialize -> session/new(cwd:) -> session/prompt
   - minimal v1: user/system messages and status updates render in-pane
```

```
                     +---------------------------+
                     |      AgentPaneView        |
                     |  +---------------------+  |
                     |  | Header: Devin icon  |  |
                     |  | project/status text |  |
                     |  +---------------------+  |
                     |  | ScrollView          |  |
                     |  |  AgentMessageRow x N  |
                     |  |  (user/system v1)   |  |
                     |  +---------------------+  |
                     |  | Composer + controls |  |
                     |  | [input] [project] [send/stop] |
                     |  +---------------------+  |
                     +---------------------------+
                               |
                     DevinSessionManager (@MainActor ObservableObject)
                               |
                         ACPClient (Process + NDJSON-RPC)
                               |
                        devin acp (subprocess, stdio)
```

## Implementation Checklist

### Phase 1: Domain Model

- [x] Add `WorkspaceKind` enum (`.terminal`, `.agent`) to `WorkspaceStore.swift`
- [x] Add `AgentProvider` enum (`.devin`) to `WorkspaceStore.swift`
- [x] Add fields to `Workspace` struct: `kind`, `agentProvider`, `committed`, `agentProjectPath`, `agentSessionID`
- [x] Backward-compatible decoding: `decodeIfPresent` with defaults (`.terminal`, `true`, nil, nil, nil)
- [x] Add `@Published var newWorkspacePopoverOpen: Bool` to `WorkspaceStore`
- [x] Add `showNewWorkspacePopover()` method (auto-expand sidebar if collapsed, set flag)
- [x] Modify `activeWorkspaces`: filter out `!committed` workspaces
- [x] Add `addAgentWorkspace(provider:projectPath:)` method (`projectPath` is optional for draft agent panes)
- [x] Add project path helpers: standardize/validate folder paths, set project path, derive project display name, list recent valid committed projects
- [x] Add `commitAgentWorkspace(_ id: UUID)` method
- [x] Auto-cleanup uncommitted workspaces in `selectWorkspace()`
- [x] Strip uncommitted workspaces in `Persistence.save()`
- [x] Guard `splitFocused()`: no-op + beep for `.agent` workspaces
- [x] Guard `newTab()`: beep for `.agent` workspaces (v1: one session per workspace)
- [x] Modify `liveIconKind(for:)`: short-circuit to `.devin` for agent workspaces
- [x] Modify `archiveWorkspace()`: close agent session before archiving (TODO marker for Phase 5)
- [x] Modify `deleteWorkspace()`: close session + remove conversation file (TODO marker for Phase 5)
- [x] Create `GlintTests/WorkspaceKindTests.swift` + `WorkspaceAgentCodableTests.swift`
  - [x] Old state.json decodes with `kind = .terminal, committed = true`
  - [x] `addAgentWorkspace` sets correct fields
  - [x] `addAgentWorkspace` can create a pathless draft
  - [x] `setAgentProjectPath` updates auto names and rejects missing folders
  - [x] `activeWorkspaces` excludes uncommitted
  - [x] `commitAgentWorkspace` makes workspace visible
  - [x] Auto-cleanup on workspace switch
  - [x] `splitFocused` no-op for agent workspace
  - [x] `liveIconKind` returns `.devin` for agent workspace
  - [x] `save()` strips uncommitted workspaces

### Phase 2: New Workspace Popover + Folder Picker

- [x] Create `Glint/Chrome/NewWorkspacePopover.swift`
  - [x] Terminal row: shell icon + "Terminal" + "Shell workspace" subtitle
  - [x] Devin Agent row: Devin icon + "Devin Agent" + "AI coding agent" subtitle
  - [x] Devin Agent row creates a pathless draft pane; it does not open NSOpenPanel
  - [x] Check `DevinHookInstaller.isAgentPresent()` for "Not installed" badge
  - [x] Hover states, Theme colors, AppFonts, rounded rects
- [x] Create `Glint/Chrome/FolderPicker.swift`
  - [x] `static func pickProjectFolder() async -> URL?`
  - [x] NSOpenPanel: `canChooseDirectories = true, canChooseFiles = false`
  - [x] Used only from the in-pane project dropdown's "Choose Folder..." command
- [x] Modify `Glint/Chrome/SidebarView.swift`
  - [x] Attach `.popover(isPresented: $store.newWorkspacePopoverOpen)` to `newWorkspaceCard`
  - [x] `filteredActiveWorkspaces`: also filter `committed`
  - [x] Agent workspace card context menu: "Archive Session" / "Resume Session"
  - [x] Agent workspace `workspaceMetadataRow`: show project folder name instead of "N tabs . M panes"
- [x] Modify `Glint/Chrome/ContentView.swift`
  - [x] `WorkspaceSwitcherPopover`: filter out `!committed` workspaces
  - [x] `newWorkspaceRow`: set `store.newWorkspacePopoverOpen = true` instead of direct `addWorkspace()`
- [x] Modify `Glint/Chrome/CommandPalette.swift`
  - [x] Replace single "New Workspace" with "New Terminal" + "New Devin Agent"
  - [x] "New Devin Agent" creates a pathless draft pane; it does not open NSOpenPanel
  - [x] Hide "Split Right" / "Split Down" when selected workspace is `.agent`
- [x] Modify `Glint/App/GlintApp.swift`
  - [x] Cmd+N: call `workspaceStore.showNewWorkspacePopover()` instead of `addWorkspace()`

### Phase 3: ACP Client (Devin Integration Layer)

- [x] Create `Glint/Agent/ACP/ACPClient.swift` minimal first-send client
  - [x] Resolve `devin` binary from common GUI-safe paths and PATH
  - [x] Spawn `devin acp` with stdin/stdout/stderr pipes
  - [x] Request helper writes newline-delimited JSON-RPC and reads matching response lines
  - [x] Minimal methods: `initialize`, `session/new(cwd:)`, `session/prompt`
  - [x] Capture stderr for diagnostics
  - [x] Fail when `session/new` does not return a non-empty session id
  - [x] Close/terminate process on stop/teardown
- [x] Create `Glint/Agent/DevinSessionManager.swift` minimal first-send manager
  - [x] Published: `messages`, `status`, `sessionID`
  - [x] Message model: `.user`, `.assistant`, `.system` (assistant reserved for streaming later)
  - [x] First-send lifecycle: start process -> initialize -> new session -> prompt
  - [x] Stop/cancel uses a run-id fence so stale process failures do not overwrite stopped state
  - [x] PaneAgentState bridge: map session status -> sidebar/tab Devin status
- [x] Create `GlintTests/ACPTypesTests.swift`
  - [x] Empty result response decoding
  - [x] New session response decoding (`sessionId` and `sessionID`)
  - [x] Error response decoding
- [ ] Expand ACP type coverage in `Glint/Agent/ACP/ACPTypes.swift`
  - [ ] JSON-RPC envelope: `ACPRequest`, `ACPResponse`, `ACPNotification`, `ACPError`
  - [ ] `InitializeRequest/Response`
  - [ ] `NewSessionRequest` (cwd, mcpServers) / `NewSessionResponse` (sessionId, models, modes, configOptions)
  - [ ] `PromptRequest/Response`
  - [ ] `LoadSessionRequest/Response`, `CloseSessionRequest/Response`
  - [ ] `SessionNotification` (sessionId, update: `SessionUpdate`)
  - [ ] `SessionUpdate` discriminated union (11 variants): `userMessageChunk`, `agentMessageChunk`, `agentThoughtChunk`, `toolCall`, `toolCallUpdate`, `plan`, `usageUpdate`, `sessionInfoUpdate`, `currentModeUpdate`, `availableCommandsUpdate`, `configOptionUpdate`
  - [ ] Content types: `TextContent`, `ImageContent`, `ResourceLinkContent`
  - [ ] `ToolKind`, `ToolCallStatus`
  - [ ] `RequestPermissionRequest/Response`, `ElicitationRequest/Response`
  - [ ] `ReadTextFileRequest/Response`, `WriteTextFileRequest/Response`
  - [ ] `CreateTerminalRequest/Response`, `TerminalOutputRequest/Response`, `KillTerminalRequest/Response`
  - [ ] `AuthenticateRequest/Response`
  - [ ] Tolerant decoding: unknown keys ignored, missing optionals defaulted
- [ ] Expand `Glint/Agent/ACP/ACPClient.swift`
  - [ ] Background reader on stdout: line-split, JSON decode, route messages
  - [ ] Routing: response (has id) -> pending CheckedContinuation; notification (no id) -> PassthroughSubject; server request (method + id) -> handler closures
  - [ ] `func notify(method:params:) throws`
  - [ ] Crash detection: `Process.terminationHandler` -> fail pending continuations + publish event
- [ ] Expand `Glint/Agent/DevinSessionManager.swift`
  - [ ] Published: `pendingPermission`, `pendingElicitation`, `sessionTitle`, `usageInfo`, `models`, `currentModel`, `modes`, `currentMode`
  - [ ] Extend message model: `.thought`, `.toolCall`
  - [ ] Streaming chunk assembly: buffer `agentMessageChunk` by `messageId`
  - [ ] `toolCallUpdate`: find existing `.toolCall` by `toolCallId`, update in-place
  - [ ] Permission handling: set `pendingPermission`, UI shows overlay, user responds
  - [ ] Elicitation handling: same pattern
  - [ ] Conversation persistence: serialize to `~/.glint/sessions/<workspaceID>.json`
  - [ ] File handlers: read/write within project root only (path validation security)
  - [ ] Terminal handlers: return "not implemented" (v1)
- [ ] Expand `GlintTests/ACPTypesTests.swift`
  - [ ] SessionUpdate discriminated union (each variant)
  - [ ] Tolerant unknown-field handling

### Phase 4: Agent Pane UI

- [x] Create `Glint/Pane/AgentPaneView.swift` minimal first-send pane
  - [x] Header: Devin icon, workspace/project label, status text
  - [x] Empty state and message list
  - [x] TextEditor composer with placeholder
  - [x] Project dropdown under the message box
  - [x] Recent valid committed agent projects
  - [x] "Choose Folder..." opens `FolderPicker.pickProjectFolder()`
  - [x] Send disabled until message and valid project folder are present
  - [x] Inline project-folder errors for missing/deleted folders
  - [x] Stop button calls `manager.stop()`
- [ ] Expand `Glint/Pane/AgentPaneView.swift`
  - [ ] Header bar: model dropdown + mode pill + status dot
  - [ ] Message list: ScrollViewReader
  - [ ] Smart auto-scroll: only scroll to bottom if user was already near bottom
  - [ ] Permission overlay: blur backdrop + card + Approve/Deny buttons
  - [ ] Elicitation overlay: form + submit
  - [ ] Error banner: red bar + message + "Restart Session" button
  - [ ] Auth needed state: instruction card
  - [ ] Not installed state: install instructions card
  - [ ] Loading state: centered ProgressView
  - [ ] Split `AgentComposer` and `AgentMessageView` into dedicated files if the pane grows
- [x] Implement first-send composer behavior
  - [ ] Send: Cmd+Return or button. Disabled when thinking/permission/empty
  - [x] On first send: validate project -> set project path -> `commitAgentWorkspace()` -> `sendFirstPrompt`
  - [x] Stop button: visible when thinking/starting, calls `manager.stop()`
- [ ] Expand composer behavior
  - [ ] Mode toggle: pill dropdown for mode switching
  - [ ] Auto-grow height up to ~120pt
- [ ] Expand message rendering
  - [ ] User message: right-aligned bubble, accent tint background
  - [ ] Assistant message: left-aligned, Devin icon gutter, `AttributedString(markdown:)`, blinking cursor while streaming
  - [ ] Thought block: collapsible, dimmed, italic, preview when collapsed
  - [ ] Tool call: compact row with kind icon + title + status badge (Capsule). Expandable detail.
  - [ ] System message: centered, dimmed, small font
- [x] Modify `Glint/Pane/PaneView.swift`
  - [x] Check `workspace.kind` to route `.terminal` -> GhosttyKit, `.agent` -> AgentPaneView
  - [x] Agent panes use `Theme.bgPane` as backing

### Phase 5: Wiring

- [x] Add `agentSessions: [WorkspacePaneKey: DevinSessionManager]` to `WorkspaceStore`
- [x] Add `agentSession(workspaceID:paneID:) -> DevinSessionManager` (lazy creation)
- [x] On workspace archive/delete/tab/pane close: stop and drop live agent session
- [ ] On workspace archive: preserve conversation file
- [ ] On workspace delete: remove conversation file
- [ ] On app quit: gracefully close all live sessions (2s timeout)
- [ ] `paneNeedsCloseConfirmation()`: return true for agent panes where session is `.thinking`
- [x] Run `xcodegen generate`

### Phase 6: Verification

- [x] All existing tests pass
- [x] New tests pass
- [ ] Manual: Cmd+N -> popover appears (sidebar auto-expands if collapsed)
- [ ] Manual: "Terminal" -> terminal workspace (same as before)
- [ ] Manual: "Devin Agent" -> draft agent pane appears immediately, NO folder dialog
- [ ] Manual: In-pane "Choose Folder..." -> cancel -> draft pane remains open and unchanged
- [ ] Manual: In-pane "Choose Folder..." -> select -> project dropdown updates, NO sidebar card before first send
- [ ] Manual: Type message + send -> sidebar card appears, agent responds with streaming text
- [ ] Manual: Tool calls render with status badges
- [ ] Manual: Permission request -> overlay with Approve/Deny
- [ ] Manual: Stop button -> cancels turn
- [ ] Manual: Switch workspace before first message -> agent workspace vanishes
- [ ] Manual: Right-click agent card -> "Archive Session" -> archived section
- [ ] Manual: Unarchive -> read-only conversation + "Resume" button
- [ ] Manual: Cmd+D in agent workspace -> beep
- [ ] Manual: Quit + relaunch -> committed agent workspaces restored, uncommitted discarded

## Edge Cases

| Edge Case | Handling |
|---|---|
| Old `state.json` missing `kind`/`committed` | `decodeIfPresent` -> `.terminal` / `true` |
| "New Devin Agent" chosen | Draft pane is created immediately; no folder dialog |
| Folder picker cancelled from in-pane dropdown | Draft pane stays open; project selection is unchanged |
| Selected folder deleted before send | Send disabled / inline error until a valid folder is chosen |
| `session/new` returns no session id | First send fails before `session/prompt` with an invalid-response error |
| User presses Stop while first send is in flight | Run-id fence ignores stale completion/failure from the stopped process |
| User switches workspace before first message | Uncommitted workspace auto-deleted |
| App quits with uncommitted workspace | Stripped from state in `save()` |
| Cmd+N with sidebar collapsed | Auto-expand sidebar, then show popover |
| `devin` binary not found (GUI PATH) | `AgentPresence.commandExists` searches common paths; show install instructions |
| `devin acp` crashes during first send | Pane shows a system error message and failed status |
| `devin acp` crashes mid-session | Future: `terminationHandler` -> `.error`, pending continuations failed, "Restart" button |
| ACP needs authentication | `initialize` response -> `.needsAuth`, show "Run `devin auth login`" card |
| Multiple `agentMessageChunk` same `messageId` | Buffer + append to single `.assistant` message |
| `toolCallUpdate` for existing tool call | Find by `toolCallId`, update in-place |
| Unknown `sessionUpdate` variant | Ignored (tolerant decoding), logged |
| User closes workspace while agent thinking | Confirmation dialog -> `cancel()` -> `close()` -> terminate |
| Permission pending on workspace close | Send "deny" response before teardown |
| Split pane in agent workspace | Guard -> beep, no-op |
| New tab in agent workspace | Beep (v1) |
| Archive agent workspace | Close session, preserve conversation JSON, drop surfaces |
| Unarchive agent workspace | Read-only conversation + "Resume Session" button |
| Delete agent workspace | Close session, remove conversation file |
| WorkspaceSwitcherPopover | Filter out `!committed` workspaces |
| Cmd+1-9 skip uncommitted | `activeWorkspaces` filters `committed` |
| Agent sidebar card idle row | Project folder name, not "N tabs . M panes" |
| Agent context menu | "Archive Session" / "Resume Session" |
| CommandPalette new workspace | Two items: "New Terminal" + "New Devin Agent"; Devin creates a draft pane with no dialog |
| File request outside project root | Reject with error (security) |
| Terminal request from agent | Return "not implemented" (v1) |
| Auto-scroll while reading history | Track scroll position; only auto-scroll if near bottom |
| Large conversation persistence | Separate file per workspace, not in `state.json` |
| Multiple agent workspaces simultaneously | Each gets own ACPClient + subprocess |

## Files Summary

**Created or added in current agent phases:**
- `Glint/Chrome/NewWorkspacePopover.swift`
- `Glint/Chrome/FolderPicker.swift`
- `Glint/Agent/ACP/ACPClient.swift`
- `Glint/Agent/DevinSessionManager.swift`
- `Glint/Pane/AgentPaneView.swift`
- `GlintTests/WorkspaceKindTests.swift`
- `GlintTests/ACPTypesTests.swift`

**Still planned as the pane/protocol grows:**
- `Glint/Agent/ACP/ACPTypes.swift`
- `Glint/Pane/AgentComposer.swift`
- `Glint/Pane/AgentMessageView.swift`

**Modified:**
- `Glint/Workspace/WorkspaceStore.swift`
- `Glint/Chrome/SidebarView.swift`
- `Glint/Chrome/ContentView.swift`
- `Glint/Chrome/CommandPalette.swift`
- `Glint/App/GlintApp.swift`
- `Glint/Pane/PaneView.swift`
