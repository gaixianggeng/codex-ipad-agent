## Context

当前实现已经跑通了 `agentd -> codex app-server stdio://` 的桥接：Go 进程启动 app-server、完成 initialize、调用 `thread/*` 和 `turn/*`，再把 Codex 通知转换成移动端自定义 REST/WS 协议。这个设计降低了 Swift 首版实现成本，但现在形成了三层协议：

```text
iPad UI internal event
  <- agentd mobile REST/WS
  <- Go CodexAppServerRuntime translation
  <- codex app-server JSON-RPC
```

OpenAI Codex app-server 官方文档把 app-server 定位为 rich client 协议，已经提供 thread、turn、history、streamed events 和 approvals。原生 iPad App 可以在 WebSocket 握手中带 `Authorization`，不受浏览器 WebSocket header 限制，因此适合直接消费 app-server 协议。浏览器/PWA 仍不适合裸连 app-server，因为浏览器会带 `Origin` 且不能设置 `Authorization` header。

现有 OpenSpec `adopt-codex-app-server-ios26` 的前提是“iOS 保持轻量，Go 封装 experimental 协议”。本变更反转该前提：Swift 端成为 app-server 一等客户端；Go 端成为 Mac control-plane 和可选 raw gateway。

## Goals / Non-Goals

**Goals:**

- iPad 原生 App 直接发送和接收 Codex app-server JSON-RPC 消息。
- Go 不再把 `thread/*`、`turn/*`、`item/*` 转换成自定义移动端业务协议。
- 保留现有 SwiftUI Store/UI 的大部分结构，通过 Swift-side projector 把 app-server event 投影成内部 `AgentEvent`。
- 保留 `agentd` 的项目 allowlist、Token、health/doctor、静态 Web 调试和 app-server lifecycle 管理。
- 支持渐进迁移：新 direct client 可先通过 feature flag 或配置启用，旧 `/api/sessions` 作为兼容路径保留。

**Non-Goals:**

- 不为 Safari/PWA 裸连 app-server。浏览器路径继续走 agentd 兼容 API 或后续专门的 HTTPS/WSS 网关。
- 不引入数据库、队列或复杂多租户权限。
- 不在首版实现完整 IDE 文件树、编辑器或任意 app-server method 控制台。
- 不把 Codex 凭证或 OpenAI 凭证带到 iPad；iPad 只保存远程访问 token。

## Decisions

1. **Swift owns app-server JSON-RPC**

   Swift 新增 `CodexAppServerConnection` actor，负责：

   - WebSocket 连接和 `Authorization: Bearer <token>`。
   - `initialize` request 和 `initialized` notification。
   - request id、pending response、timeout、错误映射。
   - notification stream 分发。
   - server request 响应，尤其是 approval/user input。

   选择 Swift 而不是 Go 的原因：用户实际要构建的是原生 iPad rich client，app-server 协议就是 rich client 的业务边界。这样协议变化只影响 Swift 客户端，不再维护 Go 自定义协议。

2. **Swift projector keeps UI stable**

   不直接让 SwiftUI View 消费原始 JSON-RPC。新增 `CodexAppServerEventProjector`，把官方事件投影到现有内部 `AgentEvent`：

   - `turn/started` -> `.turnStarted`
   - `item/agentMessage/delta` -> `.assistantDelta`
   - `item/completed` with `agentMessage` -> `.messageCompleted`
   - command/process output delta -> `.logDelta`
   - file/diff update -> `.diffUpdated`
   - approval server request -> `.approvalRequest`
   - `turn/completed` -> `.turnCompleted`

   这样 `EventReducer`、`MessageStore`、`LogStore`、`ConversationStore` 基本不用推倒重写。

3. **Project allowlist remains a control-plane responsibility**

   iPad 仍从 `agentd` 获取项目列表，发送 app-server `thread/start`/`turn/start` 时只使用 allowlist 项目的真实路径。为了降低风险，Swift 端必须用内置 builder 生成安全参数：

   - `approvalPolicy: on-request`
   - `approvalsReviewer: user`
   - `sandbox: workspace-write`
   - `sandboxPolicy.type: workspaceWrite`
   - `sandboxPolicy.writableRoots: [project.path]`
   - `networkAccess: false`

   这不是 Go 业务协议转换，而是 Mac control-plane 向 iPad 提供“哪些项目可远程操作”的安全配置。

4. **Agentd raw gateway is policy-validating, not protocol-translating**

   如果 `agentd` 暴露 app-server WebSocket gateway，必须只做安全校验和转发：

   - Bearer Token 鉴权。
   - Host/Origin/Tailscale/loopback/TLS 策略。
   - 连接到本机 loopback app-server WebSocket endpoint。
   - 使用独立 upstream capability token file，不复用 iPad 访问 `agentd` 的 token。
   - 解析 JSON-RPC envelope 中的 `method` 和少量安全敏感 `params`。
   - 拒绝非 allowlist method、非 allowlist `cwd`、危险 approval/sandbox 参数。
   - 合法请求的原始 payload 原样转发给 app-server。

   它不能把 `thread/*`、`turn/*`、`item/*` 或 approval 消息转换成移动端自定义业务事件，也不能补全、重写或解释响应/通知。这里的目标是 authorization，不是 protocol translation。安全默认参数由 Swift builder 生成，agentd 再做 fail-closed 校验。兼容 runtime 的 managed stdio app-server 连接不作为 raw gateway upstream 复用，避免多个客户端共享同一条 stdio JSON-RPC 流造成 id、notification 和 server request 归属混乱。

5. **Compatibility path is explicit**

   旧 `CodexAppServerRuntime`、`SessionRuntime`、`/api/sessions`、`/api/sessions/{id}/ws` 暂时保留，但标记为 compatibility。iPad 原生 App 通过设置页在 compatibility/direct 之间切换；direct 真实验收稳定后，再分阶段删除：

   - 第一阶段：Swift direct client 可启用，兼容 API 保留。
   - 第二阶段：默认启用 direct client，兼容 API 只服务 Web/PWA 或回退。
   - 第三阶段：如果 PWA 不再维护，删除 Go 业务转换。

## Risks / Trade-offs

- [Risk] Swift 协议实现复杂度上升 → 通过 actor、request pending map、协议样例测试和 projector 单测控制复杂度。
- [Risk] app-server WebSocket transport 仍是实验能力 → 保留 agentd compatibility path 作为回退，并把 direct client 做成可配置。
- [Risk] 去掉 Go 业务转换后远程调用风险转移到 Swift → Swift 只暴露固定业务方法，不提供任意 JSON-RPC 控制台；thread/turn 参数通过安全 builder 生成；agentd gateway 对 method/cwd/sandbox 做 fail-closed policy validation。
- [Risk] 浏览器/PWA 与原生 App 分叉 → 文档明确 Safari/PWA 仍走 agentd 兼容 API，不追求所有客户端共享同一传输路径。
- [Risk] app-server token、endpoint 配置变多 → agentd 提供 `/api/app-server/config` 或等价 control-plane metadata，iPad 只保存 `AGENTD_TOKEN`；agentd 通过 `AGENTD_APP_SERVER_WS_TOKEN_FILE` 读取本机 upstream capability token。

## Migration Plan

1. 新增 Swift `CodexAppServerConnection`、协议模型、事件 projector 和单元测试。
2. 新增 `DirectCodexSessionClient`，实现现有 `SessionStoreAPIClient` 的 thread/session/history 操作。
3. 新增 `DirectCodexSessionWebSocketClient` 或统一 direct session controller，实现现有 `SessionWebSocketClient` 的发送、停止和审批接口。
4. `AppStore` 增加连接模式：`compat` 和 `direct`。默认先保持兼容，测试通过后再决定是否切 direct 为默认。
5. Go 增加 control-plane metadata/raw gateway 能力，并把现有 runtime translation 标注为兼容路径。
6. README、iOS README 和 OpenSpec 更新架构说明、启动方式、回退方式。
7. 验收：Swift XCTest、Go 测试、构建、真实或 fake app-server smoke。

回滚方式：把 AppStore 连接模式切回 `agentd_compat`，继续使用现有 `/api/sessions` 和 `/api/sessions/{id}/ws`。

## Known Boundaries

- gateway 不维护 `threadId -> cwd/project` 状态，因此 `thread/read`、`turn/interrupt` 只做 method/token 校验，不按 cwd 二次收敛。direct 客户端只能通过 allowlist 项目的 `thread/list`、`thread/start`、`thread/resume` 获得可操作 thread id；如果后续要防止“已知 threadId”跨项目访问，需要在 agentd 增加轻量 thread registry，而不是在转发时解析业务事件。
- gateway 只接受 JSON-RPC object params，不支持 positional array params。官方 app-server 和 Swift builder 当前都使用命名参数；保留这个限制可以让 cwd、sandbox、approval policy 校验保持简单可靠。

## Open Questions

- app-server WebSocket endpoint 是让 iPad 直接连 `ws://<mac>:<port>`，还是通过 `agentd /api/app-server/ws` raw gateway 转发？MVP 优先 raw gateway，因为它保留单一远程入口和 token。
- app-server upstream token 与 `AGENTD_TOKEN` 分离。MVP 使用 `AGENTD_APP_SERVER_WS_TOKEN_FILE` 指向 capability token file；后续可由 agentd 自动生成短期 token 和 loopback ws app-server。
- 旧 Web/PWA 是否长期维护？如果维护，需要继续保留 agentd mobile API 或为浏览器实现专门 HTTPS/WSS 网关。
