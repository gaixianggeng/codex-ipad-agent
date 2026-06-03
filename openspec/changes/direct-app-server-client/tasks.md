## 1. Planning And Compatibility Boundary

- [x] 1.1 Create proposal/design/specs for direct app-server client migration
- [x] 1.2 Mark existing Go `CodexAppServerRuntime`, `/api/sessions*`, PTY runtime, and Web/PWA mobile protocol as compatibility path in docs
- [x] 1.3 Add a connection-mode decision to iOS docs and settings: compatibility mode vs direct app-server mode

## 2. Swift App-Server JSON-RPC Client

- [x] 2.1 Add Swift JSON-RPC wire models for app-server request, response, notification, server request, error, and ids
- [x] 2.2 Implement `CodexAppServerConnection` actor with WebSocket connect, initialize/initialized, pending response map, timeout, notification stream, and server request stream
- [x] 2.3 Add request builders for `thread/list`, `thread/start`, `thread/resume`, `thread/read`, `turn/start`, and `turn/interrupt`
- [x] 2.4 Add remote-safe parameter builder that uses allowlisted project paths and rejects arbitrary cwd, `dangerFullAccess`, and `approvalPolicy=never`
- [x] 2.5 Add unit tests for JSON-RPC id matching, initialization order, app-server errors, notification routing, and server request routing

## 3. Swift Event Projection And Store Integration

- [x] 3.1 Implement `CodexAppServerEventProjector` to map app-server notifications into existing internal `AgentEvent`
- [x] 3.2 Implement approval projection and response mapping for command, file-change, permission, and user-input server requests
- [x] 3.3 Add `DirectCodexSessionClient` implementing `SessionStoreAPIClient` through app-server thread/read/list/start/resume APIs
- [x] 3.4 Add direct-mode `SessionWebSocketClient` behavior for prompt send, interrupt, approval decision, and ping without agentd `wsMessage`
- [x] 3.5 Update `AppStore` and `SessionStore` factories so direct mode is selectable while compatibility mode remains available
- [x] 3.6 Add Store tests covering direct assistant stream, completed item merge, command log, diff, turn completed, and approval decision

## 4. Agentd Control Plane And Thin Gateway

- [x] 4.1 Add `GET /api/app-server/config` or equivalent metadata endpoint returning direct-mode gateway URL and sanitized runtime information
- [x] 4.2 Add `WS /api/app-server/ws` thin gateway that authenticates clients and connects to loopback app-server WS upstream
- [x] 4.3 Add JSON-RPC policy validator for method allowlist, allowlisted cwd, sandbox defaults, and dangerous approval policy rejection
- [x] 4.4 Ensure authorized request frames are forwarded without converting app-server business protocol to mobile events
- [x] 4.5 Keep `/api/sessions*` and old session WebSocket behind explicit compatibility mode documentation
- [x] 4.6 Add Go tests for unauthorized gateway rejection, unsafe method rejection, unsafe cwd/sandbox rejection, and authorized frame passthrough
- [x] 4.7 Add independent upstream capability token file support for app-server WS gateway

## 5. Documentation And Migration

- [x] 5.1 Update README architecture from Go protocol bridge to Swift direct app-server client plus agentd control plane
- [x] 5.2 Update iOS README with direct-mode endpoint/token setup, compatibility fallback, and Safari/PWA caveats
- [x] 5.3 Update prior app-server design notes so they no longer describe Go protocol conversion as the target architecture
- [x] 5.4 Add migration and rollback steps for switching between direct mode and compatibility mode

## 6. Verification

- [x] 6.1 Run `go test ./...`
- [x] 6.2 Run `go build -o bin/agentd ./cmd/agentd`
- [x] 6.3 Run iOS XCTest or xcodebuild test target for CodexAgentPad where available
- [x] 6.4 Run a fake app-server smoke covering initialize -> thread/start -> turn/start -> notification -> approval server request
- [x] 6.5 Inspect current worktree and verify no main-path code still requires Go mobile event conversion for direct mode
