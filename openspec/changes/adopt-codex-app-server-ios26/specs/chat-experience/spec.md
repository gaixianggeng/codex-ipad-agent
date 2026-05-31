## ADDED Requirements

### Requirement: Conversation behaves like a lightweight mobile chat
The iOS client SHALL present Codex conversations with responsive chat patterns similar to a polished messaging app.

#### Scenario: User sends message
- **WHEN** the user taps send
- **THEN** the user message appears immediately in the timeline
- **AND** the composer clears without waiting for the full network round trip
- **AND** the message shows sending, sent, or failed state

#### Scenario: Assistant streams response
- **WHEN** Codex streams an assistant response
- **THEN** the response appears in one active assistant bubble
- **AND** the bubble updates smoothly without inserting many short rows
- **AND** expensive Markdown and code rendering is cached by message revision

#### Scenario: User reads while output streams
- **WHEN** the user has scrolled away from the bottom
- **THEN** new streaming output does not force-scroll the timeline
- **AND** the UI shows a new-message affordance to return to the bottom

### Requirement: Historical messages are comfortable to browse
The iOS client SHALL support long conversations without loading or rendering the entire transcript at once.

#### Scenario: Scroll upward
- **WHEN** the user scrolls near the top of the loaded timeline
- **THEN** the client loads older messages by cursor
- **AND** preserves the user's visual scroll position after insertion

#### Scenario: Long content in a message
- **WHEN** a message contains long code, logs, or structured output
- **THEN** the conversation shows a readable summary or collapsed block
- **AND** detailed logs and diffs remain available in the Inspector

#### Scenario: Runtime details appear in timeline
- **WHEN** reasoning, command, tool, or file-change events are relevant to the user
- **THEN** the timeline shows compact summary cards inspired by Litter's coding-agent conversation model
- **AND** full noisy details remain collapsed or move to the Inspector

### Requirement: Message actions are available without clutter
The iOS client SHALL expose common message actions through contextual controls instead of permanent heavy chrome.

#### Scenario: Long press message
- **WHEN** the user long-presses a message
- **THEN** the client offers relevant actions such as copy, retry, stop, inspect logs, or inspect diff
- **AND** unavailable actions are hidden for that message state

#### Scenario: Failed message
- **WHEN** a message fails to send or a turn fails
- **THEN** the message shows a clear failed state
- **AND** the user can retry from the same message row

### Requirement: Composer follows a polished mobile coding workflow
The iOS client SHALL provide a bottom composer inspired by Litter's mobile composer while keeping MVP controls focused.

#### Scenario: Composer controls
- **WHEN** the composer is visible
- **THEN** it shows text input, send, and stop/interrupt controls in a bottom safe-area surface
- **AND** pending approvals, usage/context, or task state appear as compact chips or cards above the input

#### Scenario: Long prompt
- **WHEN** the draft grows beyond the compact composer comfort range
- **THEN** the user can expand the composer for longer editing
- **AND** the existing draft and selection are preserved
