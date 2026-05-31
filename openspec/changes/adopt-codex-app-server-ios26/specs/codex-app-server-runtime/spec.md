## ADDED Requirements

### Requirement: Agentd uses Codex app-server as the default runtime
The system SHALL use Codex app-server as the default Codex runtime instead of parsing PTY terminal output.

#### Scenario: Start managed app-server runtime
- **WHEN** the user starts `agentd serve` with `AGENTD_RUNTIME=codex_app_server`
- **THEN** agentd starts `codex app-server --listen stdio://` by default
- **AND** agentd reports runtime readiness through doctor

#### Scenario: Start local socket runtime
- **WHEN** app-server transport is configured to socket mode
- **THEN** agentd only accepts unix socket or loopback endpoints
- **AND** agentd refuses non-loopback network endpoints unless an explicit unsafe development override is configured

#### Scenario: Reject unsafe app-server exposure
- **WHEN** app-server listen is configured to a non-loopback network address
- **THEN** agentd refuses to start unless an explicit unsafe override is configured
- **AND** the error explains that iPad should connect to agentd, not directly to Codex app-server

#### Scenario: Initialize protocol before requests
- **WHEN** agentd starts a new Codex app-server process
- **THEN** agentd sends `initialize` with client metadata
- **AND** sends the `initialized` notification before any thread or turn request

### Requirement: Agentd owns the JSON-RPC bridge
The system SHALL implement a bounded JSON-RPC bridge between agentd and Codex app-server instead of forwarding arbitrary client methods.

#### Scenario: Match request responses
- **WHEN** multiple app-server requests are in flight
- **THEN** agentd maps responses by request id
- **AND** returns each result or error to the correct runtime operation

#### Scenario: Dispatch notifications
- **WHEN** app-server emits thread, turn, item, command, token usage, or warning notifications
- **THEN** agentd dispatches them to the mapped session subscribers
- **AND** applies backpressure or truncation before unbounded queues form

#### Scenario: Handle server requests
- **WHEN** app-server sends an approval or user-input server request
- **THEN** agentd routes it to the mobile approval flow
- **AND** replies with decline or cancel when no client answers before timeout

### Requirement: Mobile APIs map to Codex thread and turn lifecycle
The system SHALL keep stable mobile REST/WebSocket APIs while mapping implementation to Codex app-server thread and turn methods.

#### Scenario: List sessions
- **WHEN** an authenticated client calls `GET /api/sessions`
- **THEN** agentd calls the runtime thread listing capability
- **AND** returns mobile session objects grouped by configured project

#### Scenario: Start Codex thread
- **WHEN** an authenticated client creates a session with a valid `project_id`
- **THEN** agentd calls Codex `thread/start` with the allowlisted project path as `cwd`
- **AND** returns the created thread as a mobile session

#### Scenario: Resume Codex thread
- **WHEN** an authenticated client resumes a Codex history session
- **THEN** agentd calls Codex `thread/resume`
- **AND** subsequent prompts are sent through `turn/start`

#### Scenario: Send prompt to running thread
- **WHEN** the client sends a prompt over the session WebSocket
- **THEN** agentd calls Codex `turn/start` or `turn/steer` for the mapped thread
- **AND** does not write prompt text to a PTY

#### Scenario: Report usage and rate limits
- **WHEN** Codex emits token usage or agentd reads account rate limits
- **THEN** agentd exposes mobile-friendly usage and rate limit state for the active session

### Requirement: Structured runtime events are exposed to mobile clients
The system SHALL translate Codex app-server notifications into mobile-friendly WebSocket events.

#### Scenario: Assistant streaming
- **WHEN** Codex emits assistant message deltas
- **THEN** agentd emits `assistant_delta` events with stable message and turn identifiers

#### Scenario: Command output streaming
- **WHEN** Codex emits command or process output deltas
- **THEN** agentd emits `log_delta` events separate from assistant conversation messages

#### Scenario: File changes update
- **WHEN** Codex emits file change or patch update notifications
- **THEN** agentd emits `diff_updated` events suitable for an iOS Inspector panel

#### Scenario: Turn completion
- **WHEN** Codex emits turn completion or thread status changes
- **THEN** agentd emits structured status events without relying on terminal output parsing

### Requirement: PTY runtime remains available as fallback during migration
The system SHALL allow the user or developer to run the existing PTY runtime during migration.

#### Scenario: Start PTY fallback
- **WHEN** `AGENTD_RUNTIME=pty` is configured
- **THEN** agentd uses the existing PTY-backed Codex process path
- **AND** logs that this mode is a compatibility fallback
