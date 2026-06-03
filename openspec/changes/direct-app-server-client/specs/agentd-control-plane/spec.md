## ADDED Requirements

### Requirement: Agentd provides control-plane metadata without business protocol translation
Agentd SHALL provide Mac-side metadata and lifecycle support for the native app while avoiding translation of Codex app-server business messages.

#### Scenario: List allowlisted projects
- **WHEN** the native client requests project metadata
- **THEN** agentd returns only configured or scanned allowlisted projects
- **AND** the client uses those projects to build app-server `cwd` values

#### Scenario: Provide app-server connection metadata
- **WHEN** the native client requests app-server connection metadata
- **THEN** agentd returns the remote-safe app-server endpoint or raw gateway endpoint
- **AND** it does not return OpenAI credentials or local Codex credentials

#### Scenario: Keep health and doctor endpoints
- **WHEN** the user diagnoses the service
- **THEN** agentd reports health, version, runtime availability, and sanitized app-server diagnostics
- **AND** sensitive tokens and environment values are redacted

### Requirement: Agentd raw gateway validates policy without translating protocol
Agentd SHALL proxy app-server WebSocket traffic through a thin policy gate when a raw gateway is enabled.

#### Scenario: Proxy JSON-RPC frames
- **WHEN** a native client sends app-server JSON-RPC frames through the raw gateway
- **THEN** agentd validates only the JSON-RPC method and policy-sensitive parameters
- **AND** forwards authorized request frames to app-server without converting them into a mobile business protocol
- **AND** app-server responses and notifications are forwarded back unchanged

#### Scenario: Reject unsafe request
- **WHEN** a native client sends a method, cwd, sandbox, or approval policy outside the configured remote-safe allowlist
- **THEN** agentd rejects the request before forwarding it to app-server
- **AND** the rejection is returned as a JSON-RPC error for that request id

#### Scenario: Require allowlisted project context for thread listing
- **WHEN** a native client lists app-server threads through the raw gateway
- **THEN** the request includes `cwd` from the configured project allowlist
- **AND** agentd rejects `thread/list` requests without an allowlisted `cwd`

#### Scenario: Validate named parameters only
- **WHEN** a native client sends JSON-RPC params through the raw gateway
- **THEN** agentd accepts object params used by Codex app-server
- **AND** rejects positional array params because remote policy checks depend on named `cwd`, sandbox, and approval fields

#### Scenario: Authenticate raw gateway
- **WHEN** a client opens the raw gateway WebSocket
- **THEN** agentd requires Bearer Token authentication
- **AND** rejects unauthenticated requests before connecting to app-server

#### Scenario: Authenticate loopback upstream
- **WHEN** app-server upstream requires a capability token
- **THEN** agentd reads the upstream token from configured server-side storage
- **AND** sends it only to the loopback app-server upstream
- **AND** never returns the upstream token in control-plane metadata

#### Scenario: Protect browser-origin traffic
- **WHEN** a browser-origin request attempts to use the raw gateway
- **THEN** agentd applies the configured Origin and Host policy
- **AND** documents that Safari/PWA should use the compatibility path unless a browser-safe HTTPS/WSS gateway is explicitly configured

### Requirement: Agentd compatibility protocol is explicit
Agentd SHALL keep the existing mobile REST/WebSocket protocol only as a compatibility path during migration.

#### Scenario: Native client uses direct mode
- **WHEN** the native client is configured for direct app-server mode
- **THEN** Codex thread and turn operations bypass `/api/sessions` and `/api/sessions/{id}/ws`
- **AND** agentd compatibility event conversion is not on the critical path
- **AND** the native client builds `thread/list` from a selected allowlisted project instead of sending projectless list requests

#### Scenario: Compatibility fallback
- **WHEN** app-server WebSocket transport is unavailable or direct mode fails during migration
- **THEN** the user can switch back to the existing agentd compatibility mode
- **AND** the fallback behavior remains documented and testable
