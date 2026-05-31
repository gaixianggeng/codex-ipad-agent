## ADDED Requirements

### Requirement: iOS client uses iOS 26 Liquid Glass design model
The iOS/iPadOS client SHALL use iOS/iPadOS 26 native design conventions and Liquid Glass control surfaces.

#### Scenario: iOS 26 target
- **WHEN** the project is built for the new client experience
- **THEN** the iOS target and documentation reflect iOS/iPadOS 26 as the intended baseline

#### Scenario: iPad main layout
- **WHEN** the app runs on iPad
- **THEN** the main UI uses native split navigation for projects, sessions, and the active workspace
- **AND** the layout is built from native SwiftUI navigation primitives

#### Scenario: Inspector surface
- **WHEN** the user opens runtime details
- **THEN** logs, diffs, approvals, and diagnostics appear in an Inspector attached to the workspace
- **AND** the conversation remains the primary detail surface

#### Scenario: Liquid Glass controls
- **WHEN** the app renders navigation, composer, floating actions, or approval controls
- **THEN** it uses system toolbar and Liquid Glass-style controls where appropriate
- **AND** large text-reading surfaces remain high contrast and readable

#### Scenario: Codex-only product surface
- **WHEN** the user opens settings or primary workflows
- **THEN** the UI presents only Codex-related options
- **AND** does not expose Android, Claude, OpenCode, Pi, Watch, CarPlay, or voice-only workflows

### Requirement: iOS design references Litter without copying implementation
The iOS/iPadOS client SHALL use Litter's iOS product experience as a reference for mobile interaction quality while keeping this project lightweight and Codex-only.

#### Scenario: Reference boundary
- **WHEN** designers or developers use Litter as a reference
- **THEN** they may borrow interaction patterns and architecture ideas
- **AND** they do not copy GPL source code, assets, brand identity, or non-MVP platform features

#### Scenario: Dashboard reference
- **WHEN** the user lands on the main iPad experience
- **THEN** the app shows a useful project/session dashboard with recent session previews, status indicators, and a clear new-task entry
- **AND** it avoids a blank or terminal-first home screen

#### Scenario: Conversation screen reference
- **WHEN** the user opens a session
- **THEN** the conversation view consumes a lightweight screen snapshot
- **AND** it does not directly observe or render the entire runtime state graph

### Requirement: Conversation is driven by structured Codex events
The iOS client SHALL render conversation and runtime state from structured agentd events rather than parsing terminal text as the primary source.

#### Scenario: Assistant delta
- **WHEN** the client receives `assistant_delta`
- **THEN** it updates the active assistant message by stable message ID

#### Scenario: Log delta
- **WHEN** the client receives `log_delta`
- **THEN** it appends output to the Inspector log store
- **AND** does not treat command output as assistant conversation text

#### Scenario: Diff update
- **WHEN** the client receives `diff_updated`
- **THEN** it updates the Inspector diff section without rebuilding the conversation list

#### Scenario: Approval request
- **WHEN** the client receives `approval_request`
- **THEN** it shows a contextual approval card with clear approve/reject actions

### Requirement: Mobile workflow stays focused and lightweight
The iOS client SHALL prioritize the core Codex mobile workflow over IDE-like breadth.

#### Scenario: Start task
- **WHEN** the user selects a project and sends text from the composer
- **THEN** the app starts or resumes a Codex thread and shows streaming assistant output

#### Scenario: Inspect runtime details
- **WHEN** the user needs command output, diffs, or approvals
- **THEN** the user can open the Inspector without leaving the conversation

#### Scenario: Diagnose connection
- **WHEN** connection or runtime checks fail
- **THEN** the app surfaces doctor results and suggested fixes from agentd
