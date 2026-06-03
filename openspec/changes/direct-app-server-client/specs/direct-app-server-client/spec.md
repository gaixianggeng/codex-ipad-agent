## ADDED Requirements

### Requirement: iPad client speaks Codex app-server JSON-RPC directly
The iOS/iPadOS native client SHALL communicate with Codex app-server using the app-server JSON-RPC protocol instead of agentd's mobile session REST/WebSocket protocol for Codex thread and turn operations.

#### Scenario: Initialize app-server connection
- **WHEN** the native client opens an app-server WebSocket connection
- **THEN** it sends `initialize` with client metadata and capabilities
- **AND** it sends the `initialized` notification before calling any `thread/*` or `turn/*` method

#### Scenario: Call app-server methods
- **WHEN** the user lists, starts, resumes, reads, interrupts, or sends input to a Codex session
- **THEN** the native client calls the corresponding app-server JSON-RPC method
- **AND** agentd does not translate that operation into a separate mobile business protocol

#### Scenario: Match responses by request id
- **WHEN** multiple JSON-RPC requests are in flight
- **THEN** the native client resolves each response by id
- **AND** reports app-server errors to the Store without corrupting unrelated pending requests

### Requirement: Native client projects app-server events into local UI state
The iOS/iPadOS native client SHALL project Codex app-server notifications and server requests into the app's internal state model.

#### Scenario: Assistant stream notification
- **WHEN** app-server emits `item/agentMessage/delta`
- **THEN** the client updates the active assistant message through the existing message store path
- **AND** it does not require agentd to emit an `assistant_delta` mobile event

#### Scenario: Completed assistant item
- **WHEN** app-server emits `item/completed` for an agent message
- **THEN** the client stores the final assistant message with stable thread, turn, and item identifiers
- **AND** it replaces or completes the streaming bubble instead of creating a duplicate row

#### Scenario: Runtime detail notification
- **WHEN** app-server emits command output, diff, warning, usage, or turn completion notifications
- **THEN** the client routes the event to the existing log, diff, status, or message store
- **AND** unrelated UI state such as the composer draft is not mutated

### Requirement: Native client handles app-server server requests
The iOS/iPadOS native client SHALL respond to app-server server requests, including approval and user-input requests.

#### Scenario: Approval request
- **WHEN** app-server sends a command, file-change, permission, or user-input approval request
- **THEN** the client renders an approval card with enough context for the user
- **AND** it sends a JSON-RPC response with the user's decision

#### Scenario: No approval decision
- **WHEN** an approval request times out, the connection closes, or the request is unknown
- **THEN** the client fails closed by responding decline or cancel when possible
- **AND** the UI records the failure reason for diagnostics

### Requirement: Native client enforces remote-safe Codex defaults
The iOS/iPadOS native client SHALL construct app-server thread and turn requests from allowlisted project metadata and safe runtime defaults.

#### Scenario: Start thread from project
- **WHEN** the user starts a Codex session from a project
- **THEN** the client uses the allowlisted project path as `cwd`
- **AND** it sets approval and sandbox defaults suitable for remote iPad control

#### Scenario: Reject arbitrary cwd input
- **WHEN** UI or local state attempts to start a thread with a path that is not from the project allowlist
- **THEN** the client refuses to send the app-server request
- **AND** it reports a clear error to the user
