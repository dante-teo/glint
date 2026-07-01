# Agent Orchestration Control Center

Transform Glint from a terminal-only app into an agent orchestration control center, starting with Devin CLI integration via ACP (Agent Client Protocol).

## Key UX Behaviors

1. **New Workspace picker:** Cmd+N shows a popover with two options: "Terminal" (existing) and "Devin Agent". Auto-expands sidebar if collapsed.
2. **Project folder selection:** Picking "Devin Agent" opens an NSOpenPanel folder picker. The selected path feeds into ACP `session/new(cwd:)`.
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
   NSOpenPanel (folder picker)
         |
         v
   WorkspaceStore.addAgentWorkspace(provider: .devin, projectPath: ...)
   - creates Workspace with kind=.agent, committed=false
   - selects it (pane renders), but sidebar card is hidden
         |
         v
   AgentPaneView renders (empty state: project name + composer)
         |
         v
   User types first message, hits send
   - store.commitAgentWorkspace() -> committed=true -> sidebar card appears
   - DevinSessionManager.start(projectPath:)
     - spawns `devin acp` subprocess
     - ACPClient: initialize -> session/new(cwd:) -> session/prompt
   - streaming session/update notifications drive the message list
```

```
                     +---------------------------+
                     |      AgentPaneView        |
                     |  +---------------------+  |
                     |  | Header: Devin icon  |  |
                     |  | model + mode + dot  |  |
                     |  +---------------------+  |
                     |  | ScrollView          |  |
                     |  |  AgentMessageView x N  |
                     |  |  (user, assistant,  |  |
                     |  |   thought, tool,    |  |
                     |  |   system)           |  |
                     |  +---------------------+  |
                     |  | AgentComposer       |  |
                     |  | [input] [send/stop] |  |
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
- [x] Add `addAgentWorkspace(provider:projectPath:)` method
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
  - [x] `activeWorkspaces` excludes uncommitted
  - [x] `commitAgentWorkspace` makes workspace visible
  - [x] Auto-cleanup on workspace switch
  - [x] `splitFocused` no-op for agent workspace
  - [x] `liveIconKind` returns `.devin` for agent workspace
  - [x] `save()` strips uncommitted workspaces

### Phase 2: New Workspace Popover + Folder Picker

- [ ] Create `Glint/Chrome/NewWorkspacePopover.swift`
  - [ ] Terminal row: shell icon + "Terminal" + "Shell workspace" subtitle
  - [ ] Devin Agent row: Devin icon + "Devin Agent" + "AI coding agent" subtitle
  - [ ] Check `DevinHookInstaller.isAgentPresent()` for "Not installed" badge
  - [ ] Hover states, Theme colors, AppFonts, rounded rects
- [ ] Create `Glint/Chrome/FolderPicker.swift`
  - [ ] `static func pickProjectFolder() async -> URL?`
  - [ ] NSOpenPanel: `canChooseDirectories = true, canChooseFiles = false`
- [ ] Modify `Glint/Chrome/SidebarView.swift`
  - [ ] Attach `.popover(isPresented: $store.newWorkspacePopoverOpen)` to `newWorkspaceCard`
  - [ ] `filteredActiveWorkspaces`: also filter `committed`
  - [ ] Agent workspace card context menu: "Archive Session" / "Resume Session"
  - [ ] Agent workspace `workspaceMetadataRow`: show project folder name instead of "N tabs . M panes"
- [ ] Modify `Glint/Chrome/ContentView.swift`
  - [ ] `WorkspaceSwitcherPopover`: filter out `!committed` workspaces
  - [ ] `newWorkspaceRow`: set `store.newWorkspacePopoverOpen = true` instead of direct `addWorkspace()`
- [ ] Modify `Glint/Chrome/CommandPalette.swift`
  - [ ] Replace single "New Workspace" with "New Terminal" + "New Devin Agent"
  - [ ] Hide "Split Right" / "Split Down" when selected workspace is `.agent`
- [ ] Modify `Glint/App/GlintApp.swift`
  - [ ] Cmd+N: call `workspaceStore.showNewWorkspacePopover()` instead of `addWorkspace()`

### Phase 3: ACP Client (Devin Integration Layer)

- [ ] Create `Glint/Agent/ACP/ACPTypes.swift`
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
- [ ] Create `Glint/Agent/ACP/ACPClient.swift`
  - [ ] Resolve `devin` binary via `AgentPresence.commandExists` search paths
  - [ ] Spawn `Process` with stdin/stdout/stderr pipes
  - [ ] Background reader on stdout: line-split, JSON decode, route messages
  - [ ] Routing: response (has id) -> pending CheckedContinuation; notification (no id) -> PassthroughSubject; server request (method + id) -> handler closures
  - [ ] `func request<R: Decodable>(method:params:) async throws -> R`
  - [ ] `func notify(method:params:) throws`
  - [ ] Crash detection: `Process.terminationHandler` -> fail pending continuations + publish event
  - [ ] `func close()`: close stdin, wait 2s, terminate if alive
  - [ ] Stderr capture for diagnostics
- [ ] Create `Glint/Agent/DevinSessionManager.swift`
  - [ ] Published: `messages`, `sessionStatus`, `pendingPermission`, `pendingElicitation`, `sessionTitle`, `usageInfo`, `models`, `currentModel`, `modes`, `currentMode`
  - [ ] `AgentMessage` model: `.user`, `.assistant`, `.thought`, `.toolCall`, `.system`
  - [ ] Streaming chunk assembly: buffer `agentMessageChunk` by `messageId`
  - [ ] `toolCallUpdate`: find existing `.toolCall` by `toolCallId`, update in-place
  - [ ] Lifecycle: `start(projectPath:)`, `prompt(text:)`, `cancel()`, `close()`
  - [ ] Permission handling: set `pendingPermission`, UI shows overlay, user responds
  - [ ] Elicitation handling: same pattern
  - [ ] PaneAgentState bridge: map session status -> PaneAgentStatus, write into `WorkspaceStore.paneAgentState`
  - [ ] Conversation persistence: serialize to `~/.glint/sessions/<workspaceID>.json`
  - [ ] File handlers: read/write within project root only (path validation security)
  - [ ] Terminal handlers: return "not implemented" (v1)
- [ ] Create `GlintTests/ACPTypesTests.swift`
  - [ ] JSON-RPC envelope round-trip
  - [ ] SessionUpdate discriminated union (each variant)
  - [ ] Error decoding
  - [ ] Tolerant unknown-field handling

### Phase 4: Agent Pane UI

- [ ] Create `Glint/Pane/AgentPaneView.swift`
  - [ ] Header bar: project folder name + Devin icon + model dropdown + mode pill + status dot
  - [ ] Message list: ScrollView + LazyVStack + ScrollViewReader
  - [ ] Smart auto-scroll: only scroll to bottom if user was already near bottom
  - [ ] Permission overlay: blur backdrop + card + Approve/Deny buttons
  - [ ] Elicitation overlay: form + submit
  - [ ] Error banner: red bar + message + "Restart Session" button
  - [ ] Auth needed state: instruction card
  - [ ] Not installed state: install instructions card
  - [ ] Loading state: centered ProgressView
  - [ ] Empty/pre-first-message state: project name + inviting composer
- [ ] Create `Glint/Pane/AgentComposer.swift`
  - [ ] TextEditor with "Message Devin..." placeholder
  - [ ] Send: Cmd+Return or button. Disabled when thinking/permission/empty
  - [ ] On first send: `commitAgentWorkspace()` THEN `manager.prompt(text:)`
  - [ ] Stop button: visible when thinking, calls `manager.cancel()`
  - [ ] Mode toggle: pill dropdown for mode switching
  - [ ] Auto-grow height up to ~120pt
- [ ] Create `Glint/Pane/AgentMessageView.swift`
  - [ ] User message: right-aligned bubble, accent tint background
  - [ ] Assistant message: left-aligned, Devin icon gutter, `AttributedString(markdown:)`, blinking cursor while streaming
  - [ ] Thought block: collapsible, dimmed, italic, preview when collapsed
  - [ ] Tool call: compact row with kind icon + title + status badge (Capsule). Expandable detail.
  - [ ] System message: centered, dimmed, small font
- [ ] Modify `Glint/Pane/PaneView.swift`
  - [ ] Check `workspace.kind` to route `.terminal` -> GhosttyKit, `.agent` -> AgentPaneView
  - [ ] Agent panes use `Theme.bgPane` as backing (no terminal transparency)

### Phase 5: Wiring

- [ ] Add `agentSessions: [WorkspacePaneKey: DevinSessionManager]` to `WorkspaceStore`
- [ ] Add `agentSession(workspaceID:paneID:) -> DevinSessionManager` (lazy creation)
- [ ] On workspace archive: close agent session, preserve conversation file
- [ ] On workspace delete: close session, remove conversation file
- [ ] On app quit: gracefully close all live sessions (2s timeout)
- [ ] `paneNeedsCloseConfirmation()`: return true for agent panes where session is `.thinking`
- [ ] Run `xcodegen generate`

### Phase 6: Verification

- [ ] All existing tests pass
- [ ] New tests pass
- [ ] Manual: Cmd+N -> popover appears (sidebar auto-expands if collapsed)
- [ ] Manual: "Terminal" -> terminal workspace (same as before)
- [ ] Manual: "Devin Agent" -> folder picker -> cancel -> nothing happens
- [ ] Manual: "Devin Agent" -> folder picker -> select -> agent pane, NO sidebar card
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
| Folder picker cancelled | No workspace created, popover stays |
| User switches workspace before first message | Uncommitted workspace auto-deleted |
| App quits with uncommitted workspace | Stripped from state in `save()` |
| Cmd+N with sidebar collapsed | Auto-expand sidebar, then show popover |
| `devin` binary not found (GUI PATH) | `AgentPresence.commandExists` searches common paths; show install instructions |
| `devin acp` crashes mid-session | `terminationHandler` -> `.error`, pending continuations failed, "Restart" button |
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
| CommandPalette new workspace | Two items: "New Terminal" + "New Devin Agent" |
| File request outside project root | Reject with error (security) |
| Terminal request from agent | Return "not implemented" (v1) |
| Auto-scroll while reading history | Track scroll position; only auto-scroll if near bottom |
| Large conversation persistence | Separate file per workspace, not in `state.json` |
| Multiple agent workspaces simultaneously | Each gets own ACPClient + subprocess |

## Files Summary

**Create (11):**
- `Glint/Chrome/NewWorkspacePopover.swift`
- `Glint/Chrome/FolderPicker.swift`
- `Glint/Agent/ACP/ACPTypes.swift`
- `Glint/Agent/ACP/ACPClient.swift`
- `Glint/Agent/DevinSessionManager.swift`
- `Glint/Pane/AgentPaneView.swift`
- `Glint/Pane/AgentComposer.swift`
- `Glint/Pane/AgentMessageView.swift`
- `GlintTests/WorkspaceKindTests.swift`
- `GlintTests/ACPTypesTests.swift`

**Modify (6):**
- `Glint/Workspace/WorkspaceStore.swift`
- `Glint/Chrome/SidebarView.swift`
- `Glint/Chrome/ContentView.swift`
- `Glint/Chrome/CommandPalette.swift`
- `Glint/App/GlintApp.swift`
- `Glint/Pane/PaneView.swift`
