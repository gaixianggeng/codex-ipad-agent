## ADDED Requirements

### Requirement: Composer remains responsive during streaming
The iOS client SHALL keep composer input responsive while WebSocket events are streaming.

#### Scenario: Local draft state
- **WHEN** the user types in the composer
- **THEN** draft text is stored locally in the composer view
- **AND** each keystroke does not mutate global session, log, diff, or conversation stores

#### Scenario: High-frequency assistant output
- **WHEN** assistant deltas arrive continuously
- **THEN** typing in the composer remains responsive
- **AND** composer local text changes do not trigger full conversation or log re-rendering
- **AND** conversation UI updates are batched to a low-frequency cadence suitable for reading
- **AND** the active assistant bubble is updated in place instead of inserting many short message rows

#### Scenario: Large command output
- **WHEN** command output emits large logs
- **THEN** the app batches log updates and preserves smooth text input
- **AND** log UI refreshes are capped so streaming output does not monopolize the main thread

### Requirement: Streaming stores enforce bounded memory and rendering work
The iOS client SHALL enforce memory and rendering limits for logs, messages, and diffs.

#### Scenario: Log buffer grows
- **WHEN** log content exceeds the configured maximum
- **THEN** the LogStore keeps only a tail window and records that older output was truncated
- **AND** active session log, transcript, and diff caches stay within the configured memory budget

#### Scenario: Log rendering
- **WHEN** visible log output is rendered
- **THEN** the app renders bounded log lines lazily
- **AND** does not render the entire log as one large text node

#### Scenario: Long assistant response
- **WHEN** an assistant message streams for a long time
- **THEN** the client updates the existing message in batches using a stable ID
- **AND** does not recreate the entire message list for each delta
- **AND** caches expensive Markdown or code block parsing at message scope where possible

#### Scenario: Append-only assistant stream
- **WHEN** assistant text grows by appending deltas
- **THEN** the renderer reuses stable prefix render segments
- **AND** reparses only a bounded tail window when possible

#### Scenario: Large diff update
- **WHEN** a diff update exceeds the inline rendering threshold
- **THEN** the client collapses or paginates the diff in the Inspector
- **AND** keeps the conversation view responsive

### Requirement: Performance regressions are covered by tests
The project SHALL include automated tests for key client performance risks.

#### Scenario: WebSocket actor safety
- **WHEN** tests exercise connect, receive, send, failure, and reconnect paths
- **THEN** WebSocket connection state remains serialized and does not race across callback threads

#### Scenario: Rapid typing test
- **WHEN** tests simulate 500 characters of composer input while logs stream
- **THEN** LogStore and ConversationStore update counts stay within expected bounds
- **AND** the input path stays within the configured frame budget on the supported simulator profile

#### Scenario: Large stream test
- **WHEN** tests feed large assistant and log streams into Stores
- **THEN** memory windows and throttling behavior match configured limits

#### Scenario: Diff stress test
- **WHEN** tests feed a large diff event
- **THEN** the diff store marks it as collapsed or paginated instead of eagerly rendering all rows

#### Scenario: Theme switch stress test
- **WHEN** the user switches theme during an active streaming conversation
- **THEN** visible rows update styling
- **AND** session data, message ordering, and stream buffers are not rebuilt

#### Scenario: Screen model projection cache
- **WHEN** runtime snapshots replay unchanged message items
- **THEN** the conversation screen model reuses previous projected row models
- **AND** SwiftUI receives a new snapshot only when visible row content or status actually changes
