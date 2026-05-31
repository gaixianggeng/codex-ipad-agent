## ADDED Requirements

### Requirement: Service supports Tailscale-friendly binding
The system SHALL allow the user to bind the HTTP service to a configured address, including a Tailscale IP.

#### Scenario: Bind to localhost by default
- **WHEN** no bind address is configured
- **THEN** the service listens on `127.0.0.1:8787`

#### Scenario: Bind to Tailscale IP
- **WHEN** the user configures `AGENTD_BIND` with a Tailscale IP
- **THEN** the service listens on that IP and configured port

### Requirement: Doctor checks deployment readiness
The system SHALL provide doctor checks for config, token, project paths, Codex CLI, Tailscale availability, and local HTTP readiness.

#### Scenario: Run doctor command
- **WHEN** the user runs `agentd doctor`
- **THEN** the command prints actionable checks and suggested fixes

#### Scenario: Call doctor API
- **WHEN** an authenticated client calls `/api/doctor`
- **THEN** the system returns JSON check results without exposing secrets

### Requirement: Documentation explains iPad access
The system SHALL document how to access the Web UI from iPad through Tailscale.

#### Scenario: Follow quick start
- **WHEN** the user follows the README quick start
- **THEN** they can open the Web UI from iPad using the Mac Tailscale address and token

#### Scenario: Avoid public exposure
- **WHEN** the user reads the security section
- **THEN** they see that public exposure is not recommended for MVP and Token is mandatory
