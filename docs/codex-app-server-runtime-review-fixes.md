# Codex App Server Runtime 重构 — 问题与修复清单

## 背景

本文档记录对 app-server runtime 重构的代码评审结果。评审范围：Go 后端（`internal/appserver`、`internal/httpapi`、`cmd/agentd`、`internal/config`、`internal/auth`、`internal/doctor`）。

评审方法：

- `go build ./...` / `go vet ./...` / `go test ./...` 全部通过。
- 对照本机真实 `codex app-server`（`codex-cli 0.136.0-alpha.2`）实测协议：用 `codex app-server generate-ts` 导出的 `ClientRequest` / `ServerRequest` / `ServerNotification` 校验字段，并用真实 stdio JSON-RPC 跑通 `initialize → thread/start → turn/start`。

未覆盖：iOS 端未做 Xcode 编译验证（无构建环境）。

## 总体结论

- 架构分层（`SessionRuntime` 抽象 + PTY/AppServer 双实现 + 独立 `appserver` 包）干净。
- 安全基线（query token 默认关、Bearer、Origin 同源、方法 allowlist、cwd 来自 registry）已落实。
- 默认 `runtime.type=pty`，默认路径不受影响。
- **但 `runtime.type=codex_app_server` 模式当前跑不起来**：两个阻断级 bug（B1、B2）已实测确认，外加审批回环未闭合（H1）。

## 优先级总览

| ID | 严重度 | 问题 | 影响 |
| --- | --- | --- | --- |
| B1 | 阻断 | 托管 app-server 子进程启动后被立即杀掉 | app-server 模式完全不可用 |
| B2 | 阻断 | `thread/start` 带 `runtimeWorkspaceRoots` 被服务端拒绝 | 建会话必失败 |
| H1 | 高 | 审批回环未闭合 + 权限审批响应体错误 | 命令一律被自动拒绝；权限审批可能卡死 |
| H2 | 高 | 命令输出方法名漏 `item/` 前缀 | 命令输出永远不流式推送 |
| M1 | 中 | 关停时向已关闭 channel 发送 | shutdown panic |
| M2 | 中 | 默认/超时 fail-closed 产出非法 decision | 超时兜底无法真正拒绝 |
| L1 | 低 | `diff_updated` 拿不到真实文件路径 | diff 永远是空壳 |
| L2 | 低 | reasoning 未映射；无 threadId 的 warning/error 被丢 | 诊断/推理信息缺失 |
| L3 | 低 | `ListSessions` 吞掉"项目不存在"错误 | 调用方无法区分空列表与非法项目 |
| L4 | 低 | `OverloadRetries < 0` 时 `Call` 伪装成功 | 配置健壮性 |
| L5 | 低 | 线程时间戳单位未确认（秒 vs 毫秒/字符串） | 会话排序/时间显示可能错 |
| L6 | 低 | 无 `serve()` 层集成测试 | B1/B2 这类集成 bug 全部漏网 |

---

## 阻断级

### B1. 托管的 app-server 子进程启动后被立即杀掉

**位置**：`cmd/agentd/main.go:144-145`，关联 `internal/appserver/managed.go:45`

**现象**：`runtime.type=codex_app_server` 时，serve 起来后 app-server 子进程已死，之后每个 RPC（thread/list、thread/start…）因 stdout EOF 失败；且错误发生在 `startAppServerRuntime` 成功返回之后，`fallback_pty` 不会触发。

**根因**：

```go
// main.go startAppServerRuntime
ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
defer cancel()
process, _, err := appserver.StartManaged(ctx, ...)
...
return process, runtime, nil   // return 时 defer cancel() 触发
```

`StartManaged` 内部用 `exec.CommandContext(ctx, "codex", "app-server", ...)`（`managed.go:45`），子进程生命周期绑定到这个 `ctx`。函数返回 → `cancel()` → Go `exec` 直接 Kill 子进程。30s ctx 的本意只用于 `Initialize` 握手，却被套到了整个进程寿命上。

**修复**：进程用长寿命 ctx（由 `ManagedProcess.Shutdown` 负责回收），握手超时另起 ctx。

- 方案 A（改 `managed.go`，推荐）：`StartManaged` 内部用 `context.Background()` 启动 `exec.CommandContext`，把传入的 `ctx` 只用于 `client.Initialize(ctx)`。这样调用方传超时 ctx 也安全。
- 方案 B（改 `main.go`）：进程启动用不带 `defer cancel()` 的长寿命 ctx；握手超时单独控制。

参考方向（方案 A，`managed.go`）：

```go
func StartManaged(ctx context.Context, options ManagedOptions) (*ManagedProcess, InitializeResult, error) {
    ...
    // 子进程寿命由 Shutdown 管理，不绑定握手用的 ctx
    cmd := exec.CommandContext(context.Background(), bin, "app-server", "--listen", "stdio://")
    ...
    result, err := client.Initialize(ctx) // ctx 只约束握手
    ...
}
```

**验证**：`AGENTD_RUNTIME=app_server` 启动后，等待 >30s 再调 `GET /api/sessions`，应正常返回而非报错；`appServerProcess` 仍存活。补一个集成测试（见 L6）。

---

### B2. `thread/start` 带 `runtimeWorkspaceRoots` 被服务端拒绝

**位置**：`internal/httpapi/appserver_runtime.go:680-689`（`safeThreadStartParams`）

**现象**：用代码确切参数实测：

```
{"error":{"code":-32600,"message":"thread/start.runtimeWorkspaceRoots requires experimentalApi capability"}}
```

即便修了 B1，`CreateSession` 也会卡在这里。

**根因**：`safeThreadStartParams` 发送了 `runtimeWorkspaceRoots`，该字段需要 `initialize` 时声明 `capabilities.experimentalApi=true`，而代码的 `initialize`（`client.go:87`，`main.go` 未传 `Capabilities`）没声明该能力。实测删掉该字段后 `thread/start` 正常返回；声明 capability 后也正常。

**修复**：二选一。

- 方案 A（推荐，最小改动）：从 `safeThreadStartParams` 删除 `runtimeWorkspaceRoots`。可写范围已由 `cwd` + `turn/start` 的 `sandboxPolicy.writableRoots` 约束，足够。
- 方案 B：在 `initialize` 声明 `Capabilities: {"experimentalApi": true}`（`main.go` 的 `ManagedOptions.Capabilities` 或 `ClientOptions.Capabilities`）。注意这会开启更多实验字段的行为，需要确认其它参数都按 experimental 协议走，风险更大。

参考方向（方案 A）：

```go
func safeThreadStartParams(project projects.Project) map[string]any {
    return map[string]any{
        "cwd":               project.RealPath,
        "approvalPolicy":    "on-request",
        "approvalsReviewer": "user",
        "sandbox":           "workspace-write",
        "ephemeral":         false,
    }
}
```

**验证**：`thread/start` 返回 `{"thread":{"id":...}}`，`CreateSession` 成功；`turn/start` 路径参数已实测可用，无需改。

---

## 高

### H1. 审批回环未闭合，且权限审批响应体错误

**位置**：`internal/httpapi/ws.go:229-264`（WS 输入分支）、`internal/httpapi/appserver_runtime.go:467-490`（`HandleServerRequest`）、`:527-533`（`declinedDecisionForServerRequest`）

**现象**：

1. `appServerSessionWS` 输入分支只有 `input` / `signal` / `resize` / `ping`，**没有 `approval_decision`**。
2. `HandleServerRequest` 收到审批请求时**同步立即 decline** 再广播卡片。iPad 能看到审批卡，但决定早已发出，用户点"批准"没有回传通道。
3. 因为 `approvalPolicy="on-request"`，app-server 会对需审批命令发请求，而这些被一律自动拒绝 → agent 在 iPad 上"什么都不肯做"。
4. 协议错误：`item/permissions/requestApproval` 的真实响应是 `{permissions, scope, strictAutoReview?}`，**没有 decision 字段**；但代码返回 `{"decision":"decline"}`，会反序列化失败，可能让该 turn 卡住。

**修复**（分两层）：

A. 先保证 fail-closed 正确（安全底线，必须先做）：
- `HandleServerRequest` 对 `item/permissions/requestApproval` 返回正确的"拒绝"形状——授予空权限而非 `{decision}`。需要确认空 `permissions`/`scope` 的合法表达（参考 `GrantedPermissionProfile` / `PermissionGrantScope` 的最小拒绝形态）。
- command/fileChange 的 `"decline"`、legacy 的 `"denied"` 已正确，保留。

B. 再做真正的双向审批闭环（对应设计文档 Phase 4）：
- `appServerSessionWS` 输入分支新增 `case "approval_decision"`，解析 `approval_id` / `decision` / `message`。
- `HandleServerRequest` 改为**不立即返回**：广播 `approval_request` 卡片后，把该 server request 的响应 channel 挂起（按 `approvalId`/`itemId` 索引），等待 WS 回传的 `approval_decision` 再回包；超时（默认 45s，`ServerRequestTimeout`）或断线则 fail-closed 拒绝。
- 维护一个 `pendingApprovals map[approvalID]chan decision`，`approval_decision` 到达时投递。
- 安全约束（设计文档 7 节）：超时/断线/未知类型默认拒绝；移动端不得批准 `dangerFullAccess`、`approvalPolicy=never`；permission 只能授予项目 allowlist 子集。

**验证**：
- fail-closed：构造 command/fileChange/permissions 三类 server request，确认回包形状均被 app-server 接受、turn 不卡。
- 闭环：iPad 点"批准"后命令实际执行；点"拒绝"或超时则 turn 收到拒绝。

---

### H2. 命令输出不流式推送（方法名漏 `item/` 前缀）

**位置**：`internal/httpapi/appserver_runtime.go:374`

**现象**：turn 驱动的命令输出永远不会变成 `log_delta` 推给前端。

**根因**：

```go
case "command/exec/outputDelta", "commandExecution/outputDelta", "command/execution/outputDelta", "process/outputDelta":
```

真实通知方法名是 **`item/commandExecution/outputDelta`**（payload `{threadId,turnId,itemId,delta}`），不在列表里（代码写的 `commandExecution/outputDelta` 少了 `item/`）。列表里的 `command/exec/outputDelta` 是连接级 `command/exec` 路径（base64、无 threadId、属被禁方法），匹配也会在 `threadID==""` 处丢弃。

**修复**：把 case 改为真实方法名：

```go
case "item/commandExecution/outputDelta", "process/outputDelta":
    base.Type = "log_delta"
    base.Data = firstNonEmpty(stringParam(params, "delta"), stringParam(params, "data"), stringParam(params, "text"), stringParam(params, "chunk"))
```

（`process/outputDelta` 是否需要保留取决于是否用到 process 工具；`item/commandExecution/outputDelta` 是 turn 命令输出的主路径，必须有。）

**验证**：发一个会跑命令的 prompt，确认 WS 收到 `log_delta`，命令输出进入日志面板。

---

## 中

### M1. 关停时向已关闭的 notifications channel 发送 → panic

**位置**：`internal/appserver/client.go:366`（`closeWithError` 中 `close(c.notifications)`）与 `:284-292`（`dispatchNotification`）

**现象**：关停时可能 panic（send on closed channel）。

**根因**：`closeWithError` 关闭 `c.notifications`，但 `dispatchNotification` 在 `readLoop` goroutine 里仍可能向其发送。`Close()` 由 `ManagedProcess.Shutdown` 外部 goroutine 触发，与 readLoop 并发；若 close 先发生、readLoop 又收到一行，即触发 panic。`dispatchNotification` 未检查 `c.closed`。

**修复**：让 `dispatchNotification` 在发送前/发送时感知关闭，且不再 `close(c.notifications)`（由消费者侧通过 `c.closed` 退出 range）。参考方向：

```go
func (c *Client) dispatchNotification(notification Notification) {
    select {
    case <-c.closed:
        return
    default:
    }
    select {
    case c.notifications <- notification:
    case <-c.closed:
    default:
        atomic.AddUint64(&c.droppedNotifications, 1)
    }
}
```

并在 `closeWithError` 中**不要** `close(c.notifications)`；消费者 `pumpNotifications` 改为 `select` 监听 `c.closed` 退出，而不是依赖 channel close。

**验证**：`go test -race ./internal/appserver/...`；构造"关停时仍有 stdout 输出"的 fake，确认不 panic。

---

### M2. 默认/超时兜底的 fail-closed 产出非法 decision

**位置**：`internal/appserver/client.go:337-347`（`failClosedResult`，既是默认 handler 也是 `:318` 的超时路径）

**现象**：当主 handler（`HandleServerRequest`）超时（默认 45s）时，兜底"默认拒绝"其实无法正确拒绝。

**根因**：

- 返回 `{"decision":"declined"}`，`"declined"` 在任何枚举里都不存在（legacy 要 `"denied"`，v2 command/fileChange 要 `"decline"`）。
- 判断用 `strings.Contains(req.Method, "requestApproval")`，但 legacy 的 `execCommandApproval` / `applyPatchApproval` 不含该子串 → 落到 `-32601 unsupported` 分支，对审批请求回错误而非拒绝。

**修复**：让兜底逻辑复用 H1 修好的"按方法选正确拒绝形状"的函数（同时覆盖 legacy 与 v2，permissions 用空授权形状）。建议把 `declinedDecisionForServerRequest` + permissions 空授权抽成一个公共 helper，`failClosedResult` 与 `HandleServerRequest` 共用，避免两处词汇表不一致。

**验证**：单元测试覆盖 5 类 server request（execCommandApproval、applyPatchApproval、item/commandExecution/requestApproval、item/fileChange/requestApproval、item/permissions/requestApproval）的兜底响应形状均合法。

---

## 低 / 质量

### L1. `diff_updated` 拿不到真实文件路径

**位置**：`internal/httpapi/appserver_runtime.go:377-382`

**现象**：`diff_updated` 永远是 `path="workspace", status="updated"`，拿不到真正改了哪些文件。

**根因**：代码读 `params.path` / `fileChange.path` / `status`，但 `FileChangePatchUpdatedNotification` 真实字段是 `changes: []FileUpdateChange`（无 `path`/`status`）。

**修复**：从 `changes` 数组提取每个文件的路径与变更类型，聚合成 diff 摘要（按文件汇总）。

---

### L2. reasoning 未映射；无 threadId 的 warning/error 被丢

**位置**：`internal/httpapi/appserver_runtime.go:340-404`

**现象**：`item/reasoning/textDelta` / `item/reasoning/summaryTextDelta` 没处理；`warning`/`error` 若不带 `threadId` 会在 `:349-351` 被静默丢弃。

**修复**：
- 视需要新增 reasoning delta 映射（对应设计文档 iOS Phase 2）。
- 对 `warning`/`error` 放宽 threadId 必填：无 threadId 时作为全局诊断事件处理或记日志，而非直接 `return nil`。

---

### L3. `ListSessions` 吞掉"项目不存在"错误

**位置**：`internal/httpapi/appserver_runtime.go:62-65`

**现象**：传非法 `project_id` 时返回空列表 + nil，调用方无法区分"没有会话"与"项目非法"。

**修复**：`projectFilter` 返回错误时向上传递（或显式返回 400），而非 `return SessionListPage{}, nil`。

---

### L4. `OverloadRetries < 0` 时 `Call` 伪装成功

**位置**：`internal/appserver/client.go:106-138`（结尾 `return nil`）

**现象**：`attempts = OverloadRetries + 1`，若 `OverloadRetries < 0` 则 `attempts <= 0`，循环不执行，直接 `return nil`（未发请求却返回成功）。

**修复**：构造时 clamp `OverloadRetries >= 0`，或在结尾返回明确错误而非 nil。

---

### L5. 线程时间戳单位未确认

**位置**：`internal/httpapi/appserver_runtime.go:1355-1356`（`appServerThread.CreatedAt/UpdatedAt int64`）、`:1059-1064`（`unixTime` 按秒）

**现象**：若 app-server 返回毫秒或 RFC3339 字符串，`unixTime(seconds)` 解析会错，影响会话排序（`updatedAt`）与时间显示。

**修复**：用真实 `thread/start` / `thread/list` 响应确认 `createdAt`/`updatedAt` 的实际类型与单位，必要时改解析。

---

### L6. 无 `serve()` 层集成测试

**位置**：测试体系整体

**现象**：B1、B2 这类"集成层"bug 全部漏网。`real_smoke_test.go` 带 `//go:build real_codex_smoke` + `AGENTD_REAL_CODEX_SMOKE=1` 双重 gate，普通 `go test` 不编译；且其 ctx 生命周期模式与 `main.go` 不同，结构上正好绕过 B1。

**修复**：
- 补一个不带 build-tag 的集成测试，用 fake/managed 进程模拟真实生命周期（启动 → 等待 → 调用 → 关停），覆盖 B1 的"返回后进程仍存活"。
- 补 contract 测试：用导出的 `generate-ts` / `generate-json-schema` 校验出站参数与入站事件字段名（可抓 B2、H2 这类字段/方法名漂移）。

---

## 已实测确认正确的部分（无需改）

- `initialize` 握手与 `InitializeResult` 字段（userAgent/codexHome/platformFamily/platformOs）。
- `turn/start` 全套参数：`input:[{type:"text",text,text_elements:[]}]`、`sandboxPolicy:{type:"workspaceWrite",writableRoots,networkAccess,excludeTmpdirEnvVar,excludeSlashTmp}`、`approvalPolicy:"on-request"`、`approvalsReviewer:"user"`、`clientUserMessageId` —— 实测被接受。
- `thread/list` 的 `sortKey:"updated_at"` / `sortDirection:"desc"` / `archived` / `cwd` 枚举值。
- 事件字段名：`item/agentMessage/delta.delta`、`item/completed.item.{type:"agentMessage",text}`、`turn/started.turn.id`（代码有 fallback）、`thread/tokenUsage/updated.tokenUsage.total.{inputTokens,outputTokens,totalTokens}`、`thread/status/changed.status.type`。
- 安全基线：query token 默认关、Bearer 常量时间比较、Origin 同源、WS 走 auth 前置、方法 allowlist、cwd 只来自 registry；iOS WS 用 Authorization header（不受 query token 关闭影响）。
- `clientUserMessageId` 已正确用于用户消息去重，替代旧的 rollout 时间窗匹配。

---

## 建议修复顺序

1. **B1、B2**：先让 app-server 模式能跑起来（建会话 + 发消息）。
2. **H2**：补命令输出流式（影响基本可用性）。
3. **H1-A、M2**：先把 fail-closed 改正确（安全底线）。
4. **L6**：补集成 + contract 测试，锁住已修问题、防回归。
5. **H1-B**：实现真正的双向审批闭环（设计文档 Phase 4）。
6. **M1**：修关停 panic。
7. **L1～L5**：质量与健壮性收尾。

> 切换默认到 `codex_app_server` 之前，B1/B2/H1/H2/M1/M2 必须全部修复并有测试覆盖。
