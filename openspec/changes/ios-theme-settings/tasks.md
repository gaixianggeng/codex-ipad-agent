## 1. Theme Model

- [x] 1.1 Refactor `ThemeStore` to support app-wide appearance mode, theme preset, UI font preset, code font preset, font scale, persistence, and safe defaults.
- [x] 1.2 Add token and font helper APIs so views consume `ThemeTokens` instead of checking preset names directly.

## 2. Settings Experience

- [x] 2.1 Update `CodexAgentPadApp` and settings entry points to use one shared `ThemeStore`.
- [x] 2.2 Rework Appearance settings to expose appearance mode, theme preset, UI font, code font, font scale, reset, and live preview.

## 3. Workspace Integration

- [x] 3.1 Apply theme tokens and fonts to root navigation, project sidebar, session list, and shared status pills.
- [x] 3.2 Apply theme tokens and fonts to conversation timeline, message bubbles, code blocks, empty state, and composer.
- [x] 3.3 Apply theme tokens and fonts to logs, inspector, approval, diff, and context sidebar surfaces.

## 4. Verification

- [x] 4.1 Add XCTest coverage for `ThemeStore` defaults, persistence, invalid value fallback, token selection, and font scale clamping.
- [x] 4.2 Run OpenSpec status, Xcode build, XCTest build/test commands, and a manual regression review checklist.
- [x] 4.3 Perform code review pass for scope, user-state safety, UI consistency, and regressions; fix findings.
