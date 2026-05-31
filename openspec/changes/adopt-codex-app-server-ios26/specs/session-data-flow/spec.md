## ADDED Requirements

### Requirement: Session list uses lightweight indexed data
The system SHALL load and display historical sessions through lightweight paginated session rows instead of full thread transcripts.

#### Scenario: Load project sessions
- **WHEN** the client requests sessions for a project
- **THEN** agentd returns paginated session rows with id, project id, title, status, updated time, preview, usage summary, and pending approval state
- **AND** agentd does not load full message history for every row

#### Scenario: Refresh session row
- **WHEN** a runtime event changes status, preview, usage, or pending approval state
- **THEN** the affected session row is updated by stable session id
- **AND** unrelated rows are not rebuilt

### Requirement: Messages are loaded and merged by stable identifiers
The system SHALL load historical messages in pages and merge streaming events by stable message, turn, and item identifiers.

#### Scenario: Select historical session
- **WHEN** the user opens a session
- **THEN** the client requests a recent page of messages
- **AND** older messages are loaded only when the user scrolls upward or explicitly requests history

#### Scenario: Merge assistant stream
- **WHEN** assistant delta events arrive for the active turn
- **THEN** the client appends them to the existing assistant message by stable message id
- **AND** it does not create duplicate message rows when events are replayed

#### Scenario: Reconnect after disconnect
- **WHEN** the WebSocket reconnects after interruption
- **THEN** the client refreshes the session snapshot
- **AND** reconciles messages using cursor, sequence, message id, item id, and revision

### Requirement: New session flow supports local echo and confirmation
The system SHALL make new conversation creation feel immediate while keeping backend state authoritative.

#### Scenario: Send first prompt
- **WHEN** the user sends a prompt from a selected project with no active session
- **THEN** the client creates a session through agentd
- **AND** locally echoes the user message with a client message id
- **AND** merges backend confirmation or failure into the same message row

#### Scenario: Failed create or send
- **WHEN** session creation or first turn send fails
- **THEN** the local user message is marked failed
- **AND** the user can retry without duplicating the prompt

### Requirement: Client state is normalized by responsibility
The iOS client SHALL separate session index, message pages, runtime events, approvals, diffs, themes, and local composer draft state.

#### Scenario: Runtime event arrives
- **WHEN** a high-frequency runtime event arrives
- **THEN** it updates only the relevant message, log, diff, approval, or session row snapshot
- **AND** it does not mutate composer draft state

#### Scenario: Theme changes
- **WHEN** the user switches theme
- **THEN** theme state changes independently from session and message data
- **AND** message ordering, pagination cursors, and stream buffers remain unchanged
