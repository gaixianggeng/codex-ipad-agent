# Codex App Server Runtime 重构技术文档

## 目标

本次重构目标是把当前 `agentd -> PTY -> codex --no-alt-screen` 的终端桥，升级为 `agentd -> codex app-server -> Codex core` 的结构化运行时。

重构后：

- `agentd` 继续保留，仍然是 iPad / Web 访问 Mac Codex 的唯一入口。
- iPad 端继续调用现有 REST / WebSocket API，不直接连接官方 app-server。
- `agentd` 内部从读写 PTY，改为通过 stdio JSON-RPC 管理 `codex app-server --listen stdio://`。
- 会话主数据从终端文本解析，切换为 thread / turn / item 结构化事件。
- 审批、命令、diff、token usage、turn status 等信息可以稳定展示。

非目标：

- 不让 iPad 直连 `codex app-server`。
- 不把 `agentd` 做成透明 JSON-RPC 代理。
- 不一次性重写 iOS UI。
- 不引入 Rust / UniFFI / Android / 多 Agent 重型架构。
- 不在移动端开放任意文件系统、命令执行、插件安装或配置写入能力。

## 方案

### 当前架构

当前项目的真实链路是：

```text
iPad SwiftUI App / Safari
  |
  | HTTP + WebSocket over localhost / Tailscale
  v
Mac agentd
  |
  | PTY
  v
codex --no-alt-screen
```

主要问题：

- assistant 消息依赖终端输出解析和 rollout 补洞，容易重复、漏消息或断句不准。
- 命令执行、文件变更、审批、reasoning 只能混在日志里，不适合做移动端结构化展示。
- `session` 生命周期和 Codex 原生 `thread / turn / item` 生命周期不一致。
- 重连恢复、历史分页、事件幂等都需要额外推断。
- PTY 输出是面向 TUI 的，不是稳定业务协议。

### 目标架构

目标链路：

```text
iPad SwiftUI App / Safari
  |
  | REST + WebSocket
  v
Mac agentd
  |
  | stdio JSON-RPC
  v
codex app-server --listen stdio://
  |
  v
Codex core / local credentials / project workspaces
```

核心原则：

- `agentd` 是唯一远程入口，继续负责 Token、Tailscale、项目 allowlist、doctor、移动端 API 兼容。
- app-server 默认只走 stdio 子进程，不开放 TCP 给 iPad。
- 如后续支持 socket，只允许 `unix://` 或 `127.0.0.1` 本机调试。
- iPad 只提交 `project_id`，由 `agentd` 映射为项目真实路径。
- Swift 端只消费 `agentd` 的移动端事件，不直接绑定官方 JSON-RPC 协议。

### 官方 app-server 关键事实

官方 `codex app-server` 是 Codex 用来驱动富客户端的接口，适合产品内深度集成：认证、历史、审批、流式 agent 事件。

关键协议点：

- 协议是 JSON-RPC 2.0 风格，但线上消息省略 `"jsonrpc":"2.0"`。
- 请求包含 `method`、`id`、`params`。
- 响应包含 `id` 和 `result` 或 `error`。
- 通知包含 `method`、`params`，没有 `id`。
- 默认 transport 是 `stdio://`，使用 JSONL。
- WebSocket transport 仍是 experimental / unsupported，不适合作为 iPad 远程生产入口。
- 初始化必须先发 `initialize` request，再发 `initialized` notification。
- schema 可以通过 `codex app-server generate-ts` 或 `generate-json-schema` 生成，并且与当前 Codex CLI 版本绑定。
- 过载时可能返回 JSON-RPC error `-32001`，客户端应退避重试。

官方核心模型：

```text
Thread: 一段 Codex 会话
  Turn: 一次用户请求和 agent 工作
    Item: 用户消息、assistant 消息、reasoning、命令、文件变更、工具调用等结构化单元
```

标准生命周期：

```text
initialize
initialized
thread/start 或 thread/resume
turn/start
item/started
item/agentMessage/delta
item/completed
turn/completed
```

参考资料：

- [Codex App Server 文档](https://developers.openai.com/codex/app-server)
- [openai/codex app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [Unlocking the Codex harness](https://openai.com/index/unlocking-the-codex-harness/)

## 实现

### 1. 保持移动端 API 不变

这些 API 继续保留，内部从 PTY runtime 切到 app-server runtime：

```text
GET    /api/projects
GET    /api/sessions?project_id=&cursor=&limit=
POST   /api/sessions
GET    /api/sessions/{id}
DELETE /api/sessions/{id}
GET    /api/sessions/{id}/messages?before=&limit=
WS     /api/sessions/{id}/ws
```

兼容策略：

- 旧字段不删，只新增结构化字段。
- `source` 可以继续使用 `agentd` / `codex`，后续新增 `runtime` 字段区分 `pty` / `app_server`。
- `recent_output` 保留为兼容日志，不再作为主消息来源。
- `output` WebSocket 事件保留给旧 Web/PWA；新客户端优先消费 `assistant_delta`、`message_completed`、`log_delta` 等结构化事件。

### 2. 新增 Runtime 抽象

后端新增运行时接口，隔离移动端 API 和具体 Codex 驱动方式。

```go
type Runtime interface {
    ListSessions(ctx context.Context, filter SessionFilter) (SessionPage, error)
    CreateSession(ctx context.Context, req CreateSessionRequest) (SessionSnapshot, error)
    ResumeSession(ctx context.Context, req ResumeSessionRequest) (SessionSnapshot, error)
    ReadSession(ctx context.Context, sessionID string, afterSeq int64) (SessionDetail, error)
    ReadMessages(ctx context.Context, sessionID string, cursor MessageCursor, limit int) (MessagePage, error)
    StartTurn(ctx context.Context, sessionID string, req TurnRequest) error
    SteerTurn(ctx context.Context, sessionID string, req TurnRequest) error
    InterruptTurn(ctx context.Context, sessionID string) error
    Subscribe(ctx context.Context, sessionID string, afterSeq int64) (<-chan MobileEvent, func(), error)
    Shutdown(ctx context.Context) error
}
```

实现两个 runtime：

- `PTYRuntime`：包装当前 `session.Manager`，作为 fallback。
- `CodexAppServerRuntime`：通过 `AppServerClient` 调用官方 app-server。

配置新增：

```text
AGENTD_RUNTIME=pty|app_server
AGENTD_APP_SERVER_TRANSPORT=stdio|unix
AGENTD_APP_SERVER_MANAGED=1
AGENTD_APP_SERVER_FALLBACK_PTY=1
```

默认初期仍为 `pty`。通过本机 smoke 和安全测试后，再切默认 `app_server`。

### 3. AppServerClient 设计

`AppServerClient` 负责管理 `codex app-server --listen stdio://` 子进程。

职责：

- 启动子进程。
- 发送 `initialize` 和 `initialized`。
- 管理 JSON-RPC request id。
- 分发 response、notification、server request。
- 收集 stderr 诊断日志。
- 处理 app-server 退出和重启。
- 对 `-32001` 过载错误做有限退避重试。
- 提供方法 allowlist，避免变成透明代理。

最小方法集：

```text
initialize
thread/list
thread/start
thread/resume
thread/read
thread/archive
thread/unsubscribe
turn/start
turn/steer
turn/interrupt
account/rateLimits/read
```

可选方法：

```text
model/list
thread/name/set
```

禁止移动端直接触发的方法：

```text
fs/*
process/*
command/exec*
thread/shellCommand
config/value/write
config/batchWrite
skills/config/write
plugin/install
plugin/uninstall
marketplace/*
remoteControl/*
mcpServer/tool/call
mcpServer/resource/read
experimentalFeature/enablement/set
environment/add
thread/inject_items
memory/reset
externalAgentConfig/import
```

### 4. Session 与 Thread 映射

移动端仍然使用 `session_id`，内部映射为 app-server `thread_id`。

推荐映射：

```text
session_id = "codex_" + thread_id
resume_id = thread_id
runtime   = "app_server"
source    = "codex"
```

新建会话：

```text
POST /api/sessions
  -> 校验 project_id
  -> thread/start { cwd: project.RealPath }
  -> 有 prompt 时 turn/start
  -> 返回 session snapshot + ws_url
```

继续会话：

```text
POST /api/sessions { resume_id }
  -> thread/resume { threadId: resume_id }
  -> 有 prompt 时 turn/start
```

发送输入：

```text
WS input
  -> 无 active turn: turn/start
  -> 有 active turn: turn/steer
```

停止：

```text
DELETE /api/sessions/{id}
  -> 有 active turn: turn/interrupt
  -> 无 active turn: 标记 session idle/closed
```

这里不能再简单理解为“杀进程”。app-server 是长驻进程，`DELETE` 应优先中断当前 turn，而不是关闭整个 app-server。

### 5. 事件映射

app-server 事件映射到移动端事件：

| app-server 事件 | 移动端事件 | 用途 |
| --- | --- | --- |
| `thread/started` | `session` / `session_row` | 创建或更新会话 |
| `thread/status/changed` | `session_status` | 更新运行态 |
| `turn/started` | `turn_started` | 展示正在处理 |
| `item/agentMessage/delta` | `assistant_delta` | assistant 流式文本 |
| `item/completed` user/agent message | `message_completed` | 最终消息校准 |
| command output delta | `log_delta` | 命令输出日志 |
| file change / patch update | `diff_updated` | 文件变更摘要 |
| approval server request | `approval_request` | 移动端审批卡片 |
| `turn/completed` | `turn_completed` | 结束等待态 |
| warning / error | `warning` / `error` | 诊断提示 |

移动端事件必须带稳定元数据：

```json
{
  "type": "assistant_delta",
  "session_id": "codex_thr_123",
  "turn_id": "turn_456",
  "item_id": "item_789",
  "message_id": "item_789",
  "revision": 3,
  "seq": 1024,
  "delta": {
    "role": "assistant",
    "kind": "message",
    "text": "..."
  }
}
```

幂等规则：

- `seq` 是 `agentd` 给移动端生成的单调递增事件序号，不直接复用 app-server 输出块。
- `message_id` 优先用 app-server item id。
- 同一个 `session_id + item_id + revision` 重放不能生成重复 UI。
- `message_completed` 必须能校准之前的 `assistant_delta`。
- 重连后通过 `after_seq` 或 session snapshot 恢复。

### 6. 审批闭环

迁移前必须补齐审批闭环，否则不能默认启用 app-server。

移动端流程：

```text
app-server server request
  -> agentd 映射 approval_request
  -> iOS 展示审批卡片
  -> 用户批准或拒绝
  -> WS approval_decision
  -> agentd 回包给 app-server
```

默认策略：

- 超时默认拒绝。
- WebSocket 断线默认拒绝。
- 未知审批类型默认拒绝。
- 移动端不能自动批准高风险命令、文件变更、网络权限扩展。
- 移动端不能启用 `dangerFullAccess` 或 `approvalPolicy=never`。
- permission request 只能授予项目 allowlist 内的子集。

移动端新增 WS 输入事件：

```json
{
  "type": "approval_decision",
  "approval_id": "approval_123",
  "decision": "approved",
  "message": "用户在 iPad 上批准"
}
```

拒绝：

```json
{
  "type": "approval_decision",
  "approval_id": "approval_123",
  "decision": "declined",
  "message": "用户拒绝或超时"
}
```

### 7. 安全基线

迁移 app-server 前先完成安全基线。

必须实现：

- API 和 WebSocket 只接受 Authorization Bearer Token。
- 默认禁用 query token。
- WebSocket 增加 Host / Origin allowlist。
- app-server 默认只用 stdio 子进程。
- 禁止 app-server 非 loopback TCP 暴露。
- iPad 只能提交 `project_id`，不能提交任意 `cwd`。
- 所有 cwd 必须来自 `projects.Registry`。
- app-server 方法必须走 allowlist。
- doctor 输出不能泄漏 token、socket secret、环境变量敏感值。

建议配置：

```json
{
  "listen": "127.0.0.1:8787",
  "auth": {
    "token": ""
  },
  "runtime": {
    "type": "app_server",
    "fallback": "pty"
  },
  "app_server": {
    "transport": "stdio",
    "managed": true,
    "client_info_name": "codex_ipad_agent"
  }
}
```

### 8. iOS 迁移策略

iOS 端不先大改 UI，先切数据源。

第一阶段：

- 保留当前页面结构。
- 保留 `output` 日志兼容。
- 对话主线优先消费 `assistant_delta` 和 `message_completed`。
- 一旦收到结构化 assistant 消息，就停止 PTY parser 兜底。

第二阶段：

- 增加 command summary row。
- 增加 diff inspector。
- 增加 approval card。
- 增加 turn status、token usage、rate limit 展示。

第三阶段：

- 重构为 timeline + inspector。
- reasoning / command / file change 默认摘要化。
- 完整日志和完整 diff 放 Inspector。

## 落地阶段

### Phase 0：安全前置

目标：先降低当前远程面风险。

任务：

- 禁用 query token。
- WebSocket 增加 Authorization header 校验。
- 增加 Host / Origin allowlist。
- 增加安全配置测试。

验收：

- 未带 Bearer Token 的 API / WS 全部拒绝。
- query token 默认不可用。
- 非 allowlist Origin 被拒绝。

### Phase 1：AppServerClient Spike

目标：本机打通官方 app-server 最小链路。

任务：

- 实现 stdio JSON-RPC client。
- 完成 `initialize -> initialized`。
- 跑通 `thread/start -> turn/start("只回复 ok") -> assistant delta -> turn completed`。
- 用 fake app-server 覆盖 request id、notification、error、stderr。
- 生成一次 `codex app-server generate-json-schema`，保存到临时目录做 contract 参考，不直接提交生成物。

验收：

- `AGENTD_RUNTIME=app_server` 下真实 smoke 可运行。
- app-server 崩溃时 doctor 能说明原因。

### Phase 2：Runtime 抽象

目标：移动端 API 不变，内部可切 runtime。

任务：

- 新增 `Runtime` 接口。
- 将当前 PTY session manager 包装成 `PTYRuntime`。
- 新增 `CodexAppServerRuntime`。
- `/api/sessions`、`/api/sessions/{id}`、`/messages`、WS 改为调用 runtime。

验收：

- `AGENTD_RUNTIME=pty` 行为保持不变。
- `AGENTD_RUNTIME=app_server` 支持新建会话、发送 prompt、停止 turn。

### Phase 3：结构化事件

目标：对话主线不再依赖终端 parser。

任务：

- 实现 app-server event reducer。
- 映射 `assistant_delta`、`message_completed`、`turn_started`、`turn_completed`。
- 生成稳定 `seq`、`turn_id`、`item_id`、`revision`。
- 支持 WS `after_seq` 重连。

验收：

- 流式 assistant 不重复、不丢 delta。
- `message_completed` 能校准最终消息。
- iOS 输入框在持续输出时不卡。

### Phase 4：命令、diff、审批

目标：补齐 app-server 带来的关键结构化能力。

任务：

- 映射 command output 为 `log_delta`。
- 映射 file change 为 `diff_updated`。
- 实现 `approval_request` 和 `approval_decision`。
- 审批超时 / 断线 / 未知类型默认拒绝。

验收：

- 命令输出能进入日志面板。
- diff 能按文件汇总。
- 审批请求可以批准或拒绝。
- 默认拒绝路径可测试。

### Phase 5：默认切换

目标：把 app-server runtime 设为默认，PTY 降为 fallback。

切换门槛：

- fake app-server contract test 通过。
- 真实 Codex smoke 通过。
- API 兼容测试通过。
- WS 重连测试通过。
- 审批安全测试通过。
- iOS 主要流程通过。
- doctor 能检查 app-server 版本、transport、握手状态。

## 风险与优化

### 风险 1：官方 app-server 协议仍在变化

影响：

- Go 端结构体可能和新版本 Codex CLI 不匹配。

缓解：

- 每次开发用 `codex app-server generate-json-schema` 做本机探测。
- 只实现最小方法集。
- 对未知 notification 做日志记录，不让服务崩溃。
- doctor 显示 Codex CLI 版本和 schema 兼容状态。

### 风险 2：审批流不完整导致卡死或误批

影响：

- app-server 等待客户端回包，turn 卡住。
- 移动端误批准高风险操作。

缓解：

- 未完成审批闭环前不默认启用 app-server。
- 超时、断线、未知类型默认拒绝。
- 高风险 permission 不允许移动端批准。

### 风险 3：生命周期语义变化

影响：

- 当前 `DELETE session` 是杀 PTY 进程；迁移后 app-server 是长驻进程。

缓解：

- 明确 `DELETE` 优先映射为 `turn/interrupt`。
- app-server 进程由 `agentd` 生命周期管理。
- thread archive 和 turn interrupt 分开实现。

### 风险 4：事件重复或丢失

影响：

- iOS 对话气泡重复、streaming 内容断裂、重连后状态错乱。

缓解：

- `agentd` 生成单调 `seq`。
- `item_id + revision` 作为稳定合并键。
- `message_completed` 校准最终内容。
- 重连先读 snapshot，再按 `after_seq` 补事件。

### 风险 5：暴露面扩大

影响：

- app-server 支持文件系统、进程、插件、配置写入等高风险方法。

缓解：

- `agentd` 不做透明代理。
- 方法 allowlist。
- cwd allowlist。
- 禁止移动端传 sandbox / permission 高危配置。

## 最终判断

这次重构值得做。它会把项目从“iPad 远程终端”升级为“真正的 Codex 移动客户端网关”。

但正确路线不是替换掉 `agentd`，而是让 `agentd` 从 PTY 桥升级为 app-server 网关：

```text
保留 agentd
保留移动端 API
保留 PTY fallback
先做安全和 app-server spike
再逐步切结构化事件
最后默认启用 app-server runtime
```

这样可以在不破坏当前可运行 MVP 的前提下，逐步拿到官方 app-server 的结构化能力。
