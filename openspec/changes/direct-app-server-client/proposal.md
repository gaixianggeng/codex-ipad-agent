## Why

当前 `agentd` 同时承担 Mac 入口层和 Codex app-server 业务协议转换，导致 Go 后端、Swift 客户端和官方 app-server 协议之间出现三套模型。官方 app-server 已经面向 rich client 暴露 thread、turn、事件、审批和历史能力，继续在 Go 中重包一层会增加维护成本和协议漂移风险。

本变更将 iPad 原生 App 升级为 app-server JSON-RPC 一等客户端，Go 侧降级为本机启动、安全入口和可选 raw gateway，让服务链路更短、更清晰。

## What Changes

- Swift 客户端新增 Codex app-server JSON-RPC 2.0 连接、请求响应、通知分发和 server request 响应能力。
- Swift 端直接调用 `thread/list`、`thread/start`、`thread/resume`、`thread/read`、`turn/start`、`turn/interrupt` 等 app-server 方法。
- Swift 端把 app-server 原始通知投影到现有 Store/UI 所需的内部 `AgentEvent`，不再依赖 Go 的移动端事件转换。
- `agentd` 保留项目 allowlist、Token、health/doctor、静态 Web 调试和 app-server 启动/发现能力。
- `agentd` 新增或保留 raw app-server 入口时，只做认证、Origin/TLS/loopback 保护和字节级转发，不解析或改写 `thread/*`、`turn/*`、`item/*` 业务消息。
- **BREAKING**：iPad 原生 App 的主运行路径不再使用 `/api/sessions` 和 `/api/sessions/{id}/ws` 作为 Codex 业务协议入口；这些接口只作为兼容/回退路径保留，后续可删除。
- 文档从“Go 封装 app-server experimental 协议”改为“Swift 直说官方 app-server 协议，Go 只做薄入口”。

## Capabilities

### New Capabilities

- `direct-app-server-client`: iPad 原生 App 直接消费 Codex app-server JSON-RPC 协议，负责 thread/turn/history/event/approval 生命周期。
- `agentd-control-plane`: Mac 端 `agentd` 只提供项目 allowlist、认证、健康检查、app-server 启动/发现和 raw gateway，不再做业务协议转换。

### Modified Capabilities

- `codex-app-server-runtime`: 从 Go-owned JSON-RPC bridge 改为 Swift-owned app-server client，Go runtime bridge 降级为兼容路径。
- `codex-mobile-security`: 安全边界从“agentd 方法 allowlist 后再调用 app-server”调整为“agentd 限制入口和项目范围，Swift 端强制远程安全默认参数”。
- `session-data-flow`: 会话、消息和实时事件的数据源从 agentd mobile REST/WS 迁移为 app-server thread/read 和 app-server notifications。

## Impact

- iOS:
  - `Sources/Core/API` 增加 app-server JSON-RPC client、协议模型和事件投影器。
  - `SessionStore` 默认客户端从 `AgentAPIClient` 逐步切到 app-server direct client，保留现有 Store/UI 结构。
  - XCTest 增加 JSON-RPC request/response、notification mapping、approval server request、Store integration 覆盖。
- Go:
  - `agentd` 保留项目列表、认证、doctor、配置和 app-server lifecycle。
  - app-server runtime 业务转换代码标记为 compatibility path，默认运行路径不再依赖它。
  - 可新增 raw gateway/config metadata API，避免 iPad 手写 app-server 端口和 token。
- Docs/OpenSpec:
  - 更新 README 和设计文档，明确原生 App、PWA/Safari 和兼容路径的边界。
  - 旧 Web/PWA 如继续使用浏览器，仍需要 agentd mobile API 或 raw gateway 兼容模式，不能裸连 app-server。
