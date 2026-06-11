# 生产可达性审计

## 目标

在继续做安全修复前，先明确哪些代码是当前生产路径会走到的，哪些只是调试或测试遗留。这样后续优化不会修到旧路径里，也不会误删仍有诊断价值的代码。

## 方案

当前生产形态是 iPad App 直连 `agentd` 的 app-server WebSocket gateway。`agentd` 只负责鉴权、项目 allowlist、托管本机 Codex app-server，以及转发安全校验后的 JSON-RPC frame。客户端发起的 request 和客户端回给 app-server server request 的 response 都必须经过 gateway 校验。

### 生产可达路径

| 模块 | 入口 | 说明 |
| --- | --- | --- |
| HTTP 路由 | `cmd/agentd/main.go` 的 `httpapi.NewRouterWithRuntime(..., nil)` | 生产路由没有注入旧 `SessionRuntime`。 |
| app-server gateway | `internal/httpapi/appserver_gateway.go` | iPad 的 `/api/app-server/ws` 主链路，负责方法白名单、cwd allowlist、thread 授权和策略校验。 |
| managed app-server | `internal/appserver/managed.go` 的 `StartManagedWebSocket` | 当前只启动 WebSocket transport 的 Codex app-server。 |
| 项目 allowlist | `internal/projects` + `/api/projects` + `/api/workspaces/resolve` | iPad 只能使用配置中的项目路径。 |
| iOS 直连 runtime | `CodexAppServerSessionRuntime.swift` | iOS 端直接构造 app-server JSON-RPC 请求并处理 notification/server request。 |

### 调试可达路径

| 模块 | 入口 | 说明 |
| --- | --- | --- |
| Codex history diagnostics | `/api/debug/codex-history`、`DoctorView` | 默认关闭；需要 Bearer Token 且 `debug.enable_codex_history=true` 或 `AGENTD_DEBUG_CODEX_HISTORY=true`。用于诊断本机 Codex 历史和项目映射问题，不是主业务链路。 |

### 仅测试可达或旧架构遗留

| 模块 | 现状 | 后续处理 |
| --- | --- | --- |
| `internal/httpapi/appserver_runtime.go` | 旧 REST runtime 适配层，当前生产未注入。 | P2 阶段再决定删除、收缩或保留为测试 fixture。 |
| `internal/httpapi/runtime.go` | 旧 `SessionRuntime` 接口，生产传 `nil`。 | 和旧 runtime 一起处理。 |
| `internal/session/session.go` | 旧 PTY session manager，生产只创建 manager 供诊断/兼容，主链路不调用 `Create`。 | 先不删，P2 做可达性复核后清理。 |
| `internal/appserver/client.go` 的 stdio client | 当前生产使用 WebSocket managed app-server。 | P2 阶段清理或降级为测试支持代码。 |

## 实现

近期安全修复只改生产可达路径：

1. iOS permission approval：只改 `CodexAppServerSessionRuntime.swift` 的活路径。
2. 审批 UI 状态：只改 `SessionStore` 与 Composer 审批卡，不改旧 REST runtime。
3. Gateway 安全默认值、WebSocket 限制、server request response 校验：只改 `internal/httpapi/appserver_gateway.go`。
4. agentd 误配防护：改 `internal/config` 与 HTTP 日志。

## 风险与优化

- 旧 runtime 里有一份安全逻辑副本，短期不要在里面追加新安全修复，避免制造“两套行为”。
- 删除旧代码仍有价值，但必须放在安全修复之后，并用 `go test ./...` 和 iOS 端数据流测试守住回归。
- Debug history 已加默认关闭开关；后续如果做公开发布，还应补充更细的输出脱敏策略。
- iOS 端仍保留 `100.64/10` Tailscale 裸 IP 的 HTTP 支持，这是当前 README 和配对链接的主路径；因为 ATS 不能按 Tailscale CIDR 做精确例外，当前 MVP 依赖 App 端 Endpoint 校验收窄可访问范围。上线前必须做真机 ATS/Tailscale 验证，并优先评估 MagicDNS `*.ts.net` + HTTPS 或更严格的 ATS 策略。
