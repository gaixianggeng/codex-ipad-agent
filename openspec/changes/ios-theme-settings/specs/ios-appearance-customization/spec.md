## ADDED Requirements

### Requirement: App-wide appearance mode

The iOS client SHALL allow the user to choose system, light, or dark appearance mode, and the selected mode MUST apply across the main app shell without requiring an app restart.

#### Scenario: User selects dark mode

- **WHEN** the user selects dark mode in Appearance settings
- **THEN** the root app uses a dark preferred color scheme and the main workspace updates to dark theme tokens

#### Scenario: User selects system mode

- **WHEN** the user selects system mode in Appearance settings
- **THEN** the app follows the current iPad system color scheme

### Requirement: Theme preset selection

The iOS client SHALL provide built-in theme presets for Codex, Xcode, and Gruvbox, and the selected preset MUST change the colors used by the main workspace.

#### Scenario: User selects a theme preset

- **WHEN** the user selects a built-in theme preset in Appearance settings
- **THEN** chat bubbles, surfaces, borders, accent color, and code block backgrounds use that preset's tokens

### Requirement: Font customization

The iOS client SHALL allow the user to choose a UI font preset, a code font preset, and a bounded font scale.

#### Scenario: User changes UI font

- **WHEN** the user selects a UI font preset
- **THEN** primary UI labels in the main workspace render using that font preset

#### Scenario: User changes code font

- **WHEN** the user selects a code font preset
- **THEN** code snippets and monospaced technical labels render using that code font preset

#### Scenario: User adjusts font scale

- **WHEN** the user adjusts font scale outside the supported range
- **THEN** the app clamps the value to the supported minimum or maximum

### Requirement: Appearance preference persistence

The iOS client SHALL persist appearance mode, theme preset, UI font preset, code font preset, and font scale locally.

#### Scenario: App restarts after appearance changes

- **WHEN** the app starts after the user previously changed appearance settings
- **THEN** the saved appearance preferences are restored from local storage

#### Scenario: Stored value is invalid

- **WHEN** a stored appearance preference contains an unknown value
- **THEN** the app falls back to a safe default instead of failing

### Requirement: Appearance preview

The Appearance settings screen SHALL show a live preview of chat and code styling using the current appearance selections.

#### Scenario: User changes theme settings on preview

- **WHEN** the user changes appearance mode, theme preset, or font settings
- **THEN** the preview updates immediately to reflect the active selections
