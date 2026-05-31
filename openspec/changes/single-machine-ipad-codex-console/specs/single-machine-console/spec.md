## ADDED Requirements

### Requirement: Agent service starts as a single local process
The system SHALL provide a single `agentd` process that serves the Web UI, REST APIs, and WebSocket session bridge.

#### Scenario: Start service with valid config
- **WHEN** the user starts `agentd serve` with a valid token and project config
- **THEN** the service listens on the configured address and serves the Web UI

#### Scenario: Reject empty token
- **WHEN** the user starts the service without a token and without explicit insecure mode
- **THEN** the service exits with a clear error message

### Requirement: Auth protects control APIs
The system SHALL require Bearer Token authentication for control APIs and WebSocket session connections.

#### Scenario: Missing token
- **WHEN** a client calls a protected API without a token
- **THEN** the system returns HTTP 401

#### Scenario: Valid token
- **WHEN** a client calls a protected API with the configured token
- **THEN** the system processes the request

### Requirement: Project allowlist controls working directories
The system SHALL only allow Codex sessions to start in configured allowlist project directories.

#### Scenario: List configured projects
- **WHEN** an authenticated client requests projects
- **THEN** the system returns only configured and validated projects

#### Scenario: Unknown project
- **WHEN** a client attempts to start a session for an unknown project ID
- **THEN** the system rejects the request

### Requirement: Codex session runs in selected project
The system SHALL start Codex as a PTY-backed child process with the selected project as its working directory.

#### Scenario: Start session
- **WHEN** an authenticated client starts a session for a valid project
- **THEN** the system starts Codex in that project directory and returns a session ID

#### Scenario: Stop session
- **WHEN** an authenticated client stops a running session
- **THEN** the system terminates the Codex process group and marks the session as closed

### Requirement: Web UI supports interactive terminal control
The system SHALL provide a browser UI that can view output, send input, resize, and stop a running session.

#### Scenario: Receive output
- **WHEN** Codex writes output to the PTY
- **THEN** the Web UI displays the output in near real time

#### Scenario: Send input
- **WHEN** the user submits input from the Web UI
- **THEN** the input is written to the Codex PTY

#### Scenario: Reconnect session
- **WHEN** the browser reconnects to an existing running session
- **THEN** the system sends the recent output buffer and resumes live output

### Requirement: Web UI lists project sessions
The system SHALL show multiple sessions under the selected project and allow the user to attach to an existing session.

#### Scenario: Project has multiple sessions
- **WHEN** a project has more than one session in memory
- **THEN** the Web UI lists those sessions in the project sidebar

#### Scenario: Attach existing session
- **WHEN** the user selects an existing running session
- **THEN** the Web UI reconnects to that session and replays recent terminal output

#### Scenario: Load Codex history
- **WHEN** Codex has recorded historical sessions for a configured project path
- **THEN** the Web UI lists those sessions under that project

#### Scenario: Resume Codex history
- **WHEN** the user starts or sends a prompt from a Codex history session
- **THEN** the system starts Codex with `codex resume` for that session ID

### Requirement: Conversation pane mirrors useful Codex replies
The system SHALL show user messages and extracted Codex replies in the center conversation pane while keeping the full terminal stream in the log panel.

#### Scenario: User sends prompt
- **WHEN** the user sends a prompt from the composer
- **THEN** the conversation pane shows the prompt as a user message

#### Scenario: Codex replies in terminal output
- **WHEN** Codex prints a bullet-style reply in the terminal stream
- **THEN** the conversation pane shows or updates an assistant message with that reply

### Requirement: Web UI is installable as PWA
The system SHALL provide PWA metadata and an app shell cache for the static interface.

#### Scenario: Open manifest
- **WHEN** the browser requests `/manifest.webmanifest`
- **THEN** the system returns install metadata for the Codex app

#### Scenario: Register service worker
- **WHEN** the browser supports service workers on a secure origin
- **THEN** the Web UI registers `/sw.js` and caches static shell assets
