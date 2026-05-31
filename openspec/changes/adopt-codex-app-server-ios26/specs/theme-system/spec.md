## ADDED Requirements

### Requirement: App supports switchable semantic themes
The iOS client SHALL support multiple themes through semantic design tokens rather than hard-coded colors in feature views.

#### Scenario: Select theme
- **WHEN** the user selects a theme
- **THEN** the choice is persisted locally
- **AND** the app applies semantic tokens for backgrounds, bubbles, code blocks, inspector surfaces, accents, warnings, and success states

#### Scenario: Preview theme
- **WHEN** the user browses themes
- **THEN** the Appearance screen shows a conversation preview and theme badge
- **AND** the preview updates without requiring navigation back to the conversation

#### Scenario: Follow system theme
- **WHEN** the selected theme is system
- **THEN** the app follows iOS light and dark appearance changes
- **AND** conversation readability remains stable across appearances

### Requirement: Themes respect accessibility and Liquid Glass constraints
The iOS client SHALL keep themes readable and compatible with iOS/iPadOS 26 accessibility settings.

#### Scenario: Accessibility settings change
- **WHEN** Reduce Transparency, Reduce Motion, or Increase Contrast is enabled
- **THEN** custom glass, animation, and color treatments adapt
- **AND** message text, code blocks, logs, and approval controls remain legible

#### Scenario: Custom theme uses Liquid Glass
- **WHEN** a theme customizes toolbar, composer, or floating controls
- **THEN** Liquid Glass is applied sparingly to controls
- **AND** large reading surfaces remain high contrast instead of translucent

### Requirement: Theme switching does not rebuild conversation data
The iOS client SHALL treat theme changes as visual state, not data state.

#### Scenario: Switch theme while streaming
- **WHEN** the user changes theme while assistant output is streaming
- **THEN** visible UI restyles
- **AND** active message id, pagination cursor, scroll anchor, and stream buffers remain stable

### Requirement: Theme implementation stays lighter than Litter
The iOS client SHALL borrow Litter's theme picker and token ideas without adopting a large theme catalog by default.

#### Scenario: Built-in theme catalog
- **WHEN** the app ships its initial theme system
- **THEN** it includes a small curated set of readable themes
- **AND** it leaves large VS Code theme import or extensive wallpaper customization for later changes
