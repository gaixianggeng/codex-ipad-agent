## ADDED Requirements

### Requirement: Agentd remains the only remote network surface
The system SHALL expose only agentd to iOS/iPadOS clients and SHALL keep Codex app-server local to the Mac.

#### Scenario: iPad connects over Tailscale
- **WHEN** the iPad connects to the system remotely
- **THEN** it connects to agentd REST/WebSocket APIs
- **AND** it never connects directly to Codex app-server

#### Scenario: App-server is started
- **WHEN** agentd starts or connects to Codex app-server
- **THEN** app-server uses stdio by default
- **AND** socket mode is limited to unix socket or loopback

### Requirement: Remote requests are allowlisted
The system SHALL enforce project, method, and policy allowlists before any request reaches Codex app-server.

#### Scenario: Project cwd mapping
- **WHEN** the mobile client starts or resumes a session
- **THEN** it supplies `project_id`
- **AND** agentd resolves the configured allowlisted cwd
- **AND** agentd rejects arbitrary client-supplied cwd values

#### Scenario: Method allowlist
- **WHEN** a mobile operation maps to an app-server method
- **THEN** agentd permits only the Codex thread/turn/account methods needed by the mobile workflow
- **AND** rejects high-risk file system, process, config write, plugin, marketplace, remote-control, and shell-command methods by default

#### Scenario: Remote-safe Codex policy
- **WHEN** a mobile client starts a Codex thread or turn
- **THEN** agentd enforces safe approval and sandbox defaults
- **AND** rejects `dangerFullAccess` and `approvalPolicy=never` from the remote entrypoint

### Requirement: Approvals are explicit and fail closed
The system SHALL convert Codex app-server approval requests into explicit mobile approval decisions and fail closed when no decision is available.

#### Scenario: Approval request arrives
- **WHEN** app-server requests command, file-change, permission, tool, or user-input approval
- **THEN** agentd sends a structured `approval_request` event to subscribed iOS clients
- **AND** includes enough command, file, diff, and risk context for a decision

#### Scenario: No approval decision
- **WHEN** the approval request times out, the client disconnects, or the request type is unknown
- **THEN** agentd replies to app-server with decline or cancel
- **AND** records the denial reason in session diagnostics

### Requirement: Credentials and cost signals are protected
The system SHALL protect remote access credentials and surface cost/rate-limit signals without leaking secrets.

#### Scenario: Authenticate API and WebSocket
- **WHEN** a client calls REST or WebSocket APIs
- **THEN** agentd requires Bearer Token authentication
- **AND** WebSocket uses the `Authorization` header instead of query token by default

#### Scenario: Diagnostics are generated
- **WHEN** doctor or logs report runtime state
- **THEN** they omit tokens, socket secrets, and sensitive environment values
- **AND** they may include sanitized token usage, rate limit, and runtime health state
