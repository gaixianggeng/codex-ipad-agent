## 1. Project Setup

- [x] 1.1 Initialize Go module and dependency files
- [x] 1.2 Create command, internal package, static web, and sample config structure
- [x] 1.3 Add OpenSpec validation-ready artifacts

## 2. Backend Core

- [x] 2.1 Implement config loading with environment overrides and validation
- [x] 2.2 Implement Bearer Token authentication middleware
- [x] 2.3 Implement project allowlist validation and project listing API
- [x] 2.4 Implement health, ready, version, and doctor endpoints

## 3. Codex Session Runtime

- [x] 3.1 Implement PTY-backed Codex process start with selected project directory
- [x] 3.2 Implement session manager with list, get, stop, and cleanup
- [x] 3.3 Implement WebSocket bridge for output, input, resize, ping, and exit events
- [x] 3.4 Add recent output buffer for reconnect

## 4. Web UI

- [x] 4.1 Implement iPad-friendly static HTML/CSS layout
- [x] 4.2 Implement token login, API calls, session creation, and session stop
- [x] 4.3 Implement WebSocket terminal output, input, Enter, Ctrl+C, resize, and reconnect behavior

## 5. Verification And Docs

- [x] 5.1 Add Go tests for config, auth, projects, and session-safe helpers
- [x] 5.2 Build and run smoke tests locally
- [x] 5.3 Write Chinese README with quick start, Tailscale access, safety notes, and troubleshooting
- [x] 5.4 Validate OpenSpec change

## 6. PWA And App-Like UI

- [x] 6.1 Add project-scoped session list and attach behavior
- [x] 6.2 Rework frontend toward Codex App style with conversation-first layout
- [x] 6.3 Use xterm.js for side terminal logs and submit composer input with terminal carriage return
- [x] 6.4 Add manifest, service worker, iPad web app metadata, and icon
- [x] 6.5 Load Codex native history from local state and resume history sessions
- [x] 6.6 Mirror extracted assistant replies into the center conversation pane
- [x] 6.7 Buffer terminal writes to reduce iPad input lag
