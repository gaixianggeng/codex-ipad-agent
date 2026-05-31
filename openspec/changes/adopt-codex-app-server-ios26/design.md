## Context

当前项目已经有可运行的 Go `agentd`、静态 Web/PWA 和 SwiftUI iPad App。旧运行时把 Codex 当作终端程序，通过 PTY 读写。这个模式的优点是简单，缺点是 Codex 状态只能从终端输出反推。

Codex CLI 当前提供：

```bash
codex app-server --listen stdio://
codex app-server --listen unix://
codex app-server --listen ws://127.0.0.1:8390
codex app-server daemon start
codex remote-control start
codex app-server generate-ts --out <dir>
codex app-server generate-json-schema --out <dir>
```

生成协议中已经存在 `thread/list`、`thread/start`、`thread/resume`、`thread/read`、`turn/start`、`turn/steer`、`turn/interrupt`、`item/agentMessage/delta`、`command/exec/outputDelta`、`item/fileChange/patchUpdated` 等结构化能力。新方案应优先使用这些能力。

## Goals / Non-Goals

**Goals:**

- 默认运行时从 PTY 切换到 Codex app-server。
- iOS/iPadOS App 保持轻量，只消费 `agentd` 提供的稳定移动端 API。
- `agentd` 封装 Codex experimental 协议变化，避免 Swift 客户端跟着频繁改。
- iPad 主体验按 iOS/iPadOS 26 Liquid Glass 设计推进。
- 客户端在大输出、高频事件、长会话下保持输入不卡、滚动稳定、内存有界。
- 安全边界保持单机/Tailscale、Token、allowlist。

**Non-Goals:**

- 不迁移到 Rust/UniFFI。
- 不做 Android。
- 不支持 Claude/OpenCode/Pi。
- 不做手机本地 runtime。
- 不做复杂 IDE 文件树或 Monaco 级编辑器。

## Target Architecture

```text
iOS / iPadOS 26 SwiftUI App
  |
  | HTTPS/HTTP + WebSocket over Tailscale
  v
Mac agentd
  |
  | stdio JSONL child process by default
  | optional unix:// socket for local-only control
  v
codex app-server
  |
  v
Codex core / local credentials / project workspaces
```

关键边界：

- iPad 只知道 `agentd` endpoint 和 token。
- `codex app-server` 默认不开放 TCP 端口，由 `agentd` 以 `stdio://` 子进程管理。
- 如后续切到 socket，只允许 unix socket 或 `127.0.0.1` 本机调试，不暴露到 Tailscale。
- `agentd` 只允许配置中的 `project_id` 转成 Codex `cwd`。
- Codex 凭证不离开 Mac。

## Runtime Decisions

1. **保留 `agentd` 作为稳定网关**

   不让 iOS 直接连接 Codex app-server。这样 Swift 端模型简单，Codex experimental 协议变化集中在 Go 后端处理。

2. **新增 runtime 抽象**

   后端引入类似：

   ```go
   type Runtime interface {
       ListThreads(ctx context.Context, filter ThreadFilter) ([]Thread, error)
       StartThread(ctx context.Context, req StartThreadRequest) (*Thread, error)
       ResumeThread(ctx context.Context, req ResumeThreadRequest) (*Thread, error)
       StartTurn(ctx context.Context, req StartTurnRequest) error
       InterruptTurn(ctx context.Context, threadID string) error
       ReadThread(ctx context.Context, threadID string) (*ThreadDetail, error)
       Subscribe(ctx context.Context, threadID string) (<-chan RuntimeEvent, func(), error)
   }
   ```

   第一阶段实现 `PTYRuntime` 和 `CodexAppServerRuntime` 并存；默认逐步切到 `CodexAppServerRuntime`。

3. **Codex app-server 由 `agentd` 管理**

   MVP 使用 stdio 子进程，避免端口占用、Origin 限制、Token 暴露和 Tailscale 误暴露：

   ```bash
   codex app-server --listen stdio://
   ```

   `agentd` 负责启动、初始化握手、stderr 诊断、退出清理和异常重启。后续如需要跨进程复用，可改为 `unix://` socket；`ws://127.0.0.1` 只作为本机开发调试选项。

4. **移动端 API 保持稳定**

   iOS 仍调用：

   - `GET /api/projects`
   - `GET /api/sessions`
   - `POST /api/sessions`
   - `GET /api/sessions/{id}`
   - `DELETE /api/sessions/{id}`
   - `GET /api/sessions/{id}/messages`
   - `WS /api/sessions/{id}/ws`

   内部模型从 session/PTY 映射到 thread/turn。必要时新增字段，但避免破坏 iOS 首屏流程。

5. **事件映射**

   Codex app-server -> agentd mobile event：

   - `thread/started` -> `session`
   - `thread/status/changed` -> `session_status`
   - `turn/started` -> `turn_started`
   - `item/agentMessage/delta` -> `assistant_delta`
   - `item/completed` -> `message_completed`
   - `command/exec/outputDelta` / `process/outputDelta` -> `log_delta`
   - `item/fileChange/patchUpdated` -> `diff_updated`
   - approval/server request -> `approval_request`
   - `turn/completed` -> `turn_completed`
   - error/warning -> `error` / `warning`

6. **JSON-RPC 桥只实现移动端最小能力**

   `agentd` 不做透明 JSON-RPC 代理。MVP 只调用：

   - `initialize` / `initialized`
   - `thread/list`、`thread/start`、`thread/resume`、`thread/read`、`thread/archive`、`thread/unsubscribe`
   - `turn/start`、`turn/steer`、`turn/interrupt`
   - `account/rateLimits/read`

   默认拒绝 `fs/*`、`command/exec`、`thread/shellCommand`、`process/*`、`config/*write`、`plugin/*install`、`marketplace/*`、`remoteControl/*` 等高风险方法。Codex server request 进入审批队列，不在无客户端或超时情况下自动批准。

## Litter Reference Decisions

Litter 的 iOS 体验值得参考，但本项目只借鉴交互模式和架构思想，不复制 GPL 代码、资源、品牌，也不引入 Rust/UniFFI、Android、Watch、CarPlay、语音、宠物/小游戏等非 MVP 范围。

### 1. 页面结构参考

Litter 的页面组织可以抽象成：

```text
Home dashboard / sessions
  -> conversation
  -> bottom composer
  -> appearance/theme settings
  -> rich runtime details when needed
```

本项目对应为：

```text
Projects + Sessions sidebar
  -> Workspace conversation
  -> bottom Codex composer
  -> Inspector(log/diff/approval/diagnostics)
  -> Appearance/theme settings
```

借鉴点：

- 首屏不是空白列表，而是“最近会话 + 当前项目 + 新建入口”的工作台。
- 会话 row/card 显示预览、状态点、active turn、pending approval、更新时间和快速操作。
- Conversation detail 只承载对话主线，日志/diff/approval 放 Inspector。
- 设置页提供 Appearance 入口，并内置对话预览，用户改主题时能立即看到效果。

### 2. iOS 状态架构参考

Litter 的 `ConversationScreenModel` 方向值得借鉴：View 消费投影后的 snapshot，而不是直接绑定大而全的 AppModel。我们采用轻量版本：

```text
Runtime/Event data
  -> EventReducer actor
  -> MessageStore / SessionIndexStore
  -> ConversationScreenModel snapshot
  -> ConversationTimelineView
```

关键约束：

- `ConversationScreenModel` 负责把消息、turn 状态、composer 附属状态投影成 UI snapshot。
- UI row 使用稳定 id、render digest、revision，避免高频 streaming 触发整屏重建。
- 本地 composer draft 不放入全局会话 Store，避免输入和后台输出互相影响。
- 会话列表和对话详情分开派生，active turn 更新不能让整个历史列表重排。

### 3. 对话渲染参考

Litter 的对话体验强在“内容是聊天，细节可展开”：

- 用户消息是明确气泡，支持复制/编辑/重试等上下文操作。
- assistant streaming 更新单个活跃气泡。
- reasoning、command、tool、file change 等细节用 card/section 表达，默认折叠或摘要。
- 长 Markdown/代码块分段渲染和缓存，避免每次 delta 重新解析整段文本。

本项目采用：

- `MessageBubbleView` 风格的轻量气泡系统。
- `ConversationTimelineRowDescriptor` 风格的 row 分组，但只保留 Codex 必需类型：user、assistant、reasoning summary、command summary、file change summary、approval、error。
- streaming assistant 使用 prefix/suffix 或 revision cache，优先复用稳定前缀，只解析尾部变化。
- 复杂日志和完整 diff 不进对话气泡，进入 Inspector。

### 4. Composer 参考

Litter 的底部 composer 交互值得借鉴：

- `safeAreaInset(edge: .bottom)` 固定在底部。
- 左侧 attach/上下文按钮，中间自适应输入框，右侧 send/stop。
- 输入较长时提供展开 composer。
- pending user input、plan/task、rate limit/context 等辅助信息以 chips/card 出现在输入框上方。

本项目 MVP 简化为：

- attach 可以后置，首版先支持文本 + stop/interrupt。
- 保留 expanded composer 设计点，适合 iPad 长 prompt。
- approval 和 cost/context 提示显示在 composer 上方，不挤占聊天主线。

### 5. 主题和外观参考

Litter 的主题系统基于主题定义、manifest、preview badge、Appearance 页面和 `themeVersion`。本项目采用轻量版本：

- 使用内置主题 manifest，但先提供少量高质量主题，而不是一次性塞入大量 VS Code 主题。
- 主题通过语义 token 输出到 UI，不让 View 直接引用原始 hex。
- Appearance 页面包含主题选择、字体大小、聊天预览。
- `themeVersion` 只驱动可见样式刷新，不改变 message/session 数据结构。

### 6. 性能参考

Litter 里值得借鉴的性能手段：

- snapshot 投影缓存。
- streaming assistant 前缀复用和尾部解析。
- message render cache。
- Equatable row 和 render digest。
- 对确实复杂的滚动/缩放交互，必要时用 UIKit 包一层。

本项目默认先用 SwiftUI `LazyVStack`/`ScrollView` 实现；只有当 Instruments 证明会话列表或 timeline 卡顿时，才考虑 UIKit-backed list。MVP 不做 Litter 的 pinch zoom 会话列表，这个交互很酷，但维护成本偏高。

## Session Data Flow Decisions

会话数据必须分清“索引、详情、实时事件、本地输入”四类，不混在一个全局 Store 里。

### 1. 首屏和历史会话索引

```text
App launch / pull refresh
  -> GET /api/projects
  -> GET /api/sessions?project_id=<id>&cursor=<cursor>&limit=<n>
  -> SessionIndexStore
  -> Project list + session list
```

`GET /api/sessions` 只返回轻量 session row，不读取完整 thread 内容。row 包含：

- `id` / `thread_id` / `project_id`
- `title`
- `status` / `turn_status`
- `updated_at`
- `last_message_preview`
- `token_usage_summary`
- `has_pending_approval`
- `unread_event_count`

这样历史会话列表可以快速展示和分页，不因为某个长会话拖慢首屏。

### 2. 选择会话和消息分页

```text
Tap session row
  -> GET /api/sessions/{id}
  -> GET /api/sessions/{id}/messages?before=<cursor>&limit=<n>
  -> MessagePageStore
  -> ConversationTimelineView
```

`GET /api/sessions/{id}/messages` 返回分页消息，不一次性加载完整历史。消息模型按 `message_id`、`turn_id`、`item_id` 稳定标识归一化，UI 只渲染可见窗口和附近缓存。向上滚动时再加载旧消息，保持微信式“上滑加载历史”的体验。

### 3. 新建会话和发送首条消息

```text
Composer local draft
  -> POST /api/sessions { project_id, title? }
  -> SessionIndexStore insert confirmed row
  -> WS /api/sessions/{id}/ws
  -> client sends prompt command with client_message_id
  -> agentd turn/start
  -> assistant_delta / message_completed / turn_completed
```

新建会话不使用全局草稿。composer 先保留本地 `@State`，`POST /api/sessions` 成功后才插入会话索引。发送用户消息时带 `client_message_id`，iOS 先本地回显用户气泡；后端确认或失败后按 id 合并状态，避免重复消息。

### 4. 实时事件和重连

```text
codex app-server notification
  -> agentd RuntimeEvent
  -> mobile AgentEvent { seq, session_id, turn_id, item_id, type, payload }
  -> WebSocketConnection actor
  -> EventReducer actor
  -> MainActor snapshot
```

`agentd` 给移动端事件补充单调递增 `seq`。iOS 记录每个 session 的 `last_seen_seq`，断线重连后先读取 session snapshot，再补拉消息页或重新订阅实时事件。所有 reducer 必须幂等：同一个 `message_id/item_id/revision` 重放不能产生重复 UI。

### 5. Store 边界

```text
SessionIndexStore   // 项目、会话 row、选择态
MessageStore        // 分页消息、流式 assistant 合并
WebSocketConnection // 连接和收发，不持有 UI 状态
EventReducer        // 后台归并事件，批量提交 snapshot
ApprovalStore       // pending approval
DiffStore           // 文件变化和折叠状态
ThemeStore          // 主题选择和语义 token
ComposerState       // View-local draft
```

列表 row、对话消息、日志、diff、审批、主题分开维护。高频输出只能更新 MessageStore/Log/Diff 的局部 snapshot，不能让 SessionIndexStore 和 composer 跟着重绘。

## iOS / iPadOS 26 UI Decisions

1. **iPad 使用三栏信息架构**

   ```text
   Projects + Threads | Conversation | Inspector
   ```

   使用 `NavigationSplitView`，不要自绘桌面式壳。

2. **Liquid Glass 只用于控制层**

   使用系统 toolbar、glass composer、floating approval card、compact action buttons。代码、日志、diff 内容区域保持清晰背景和高对比，不把大文本区域做成透明玻璃。

3. **Composer 是主入口**

   底部 composer 独立管理本地输入状态，不订阅日志流，不因 WebSocket output 触发重渲染。

4. **Inspector 分区**

   Detail 保留当前 Codex 工作区和对话流，日志不再作为第三列 detail，而是挂到 detail 的 Inspector 中。Inspector 内含：

   - 命令日志
   - diff / 文件变化
   - 审批请求
   - 诊断状态

5. **连接和流处理拆出主 Store**

   `SessionStore` 只保留项目、会话、选择和命令入口。WebSocket 状态和流处理拆为：

   - `WebSocketConnection` actor：负责连接、发送、接收和线程安全状态。
   - `TerminalStreamStore` actor：负责 assistant/log delta 合并、ring buffer、节流和截断统计。
   - `ApprovalStore`：维护 pending approval 和用户选择。
   - `DiffStore`：维护文件、hunk、折叠状态和可见窗口。

6. **只做 Codex 工作流**

   UI 文案、图标和设置项只围绕 Codex，不出现 Claude/OpenCode/Android 等扩展入口。

7. **对话体验向微信靠拢**

   对话区域优先做成高频使用的聊天体验，而不是终端或 IDE 日志。微信式流畅性和 Litter 式 coding-agent 信息密度结合：

   - 用户消息右侧气泡，Codex 回复左侧或中性气泡。
   - 用户发送后立即本地回显，状态依次为 `sending`、`sent`、`failed`。
   - assistant 流式回复更新同一个气泡，不插入大量碎片 row。
   - 时间分隔只在间隔明显时显示，不每条消息都占空间。
   - 上滑分页加载旧消息，底部有“回到底部”按钮和新消息提示。
   - 复制、重试、停止、查看日志、查看 diff 放在长按菜单或消息附属操作里。
   - 代码块和长输出默认保持可读，不把命令日志混进聊天气泡；日志和 diff 进入 Inspector。
   - reasoning、command、tool、file change 默认以摘要卡片出现，细节进入 Inspector 或展开区。

8. **主题系统使用语义 token**

   支持 `system`、`light`、`dark`、`highContrast` 和至少一个低干扰自定义主题。主题不直接散落在 View 中，而是通过语义 token 提供：

   - `appBackground`
   - `conversationBackground`
   - `userBubble`
   - `assistantBubble`
   - `codeBlockBackground`
   - `inspectorBackground`
   - `accent`
   - `danger`
   - `success`

   主题切换只影响可见 View 的视觉渲染，不触发消息、日志、diff 的数据重建。主题必须尊重系统 Reduce Transparency、Reduce Motion、Increase Contrast。

## Performance Decisions

- WebSocket 接收层和 Store 层分离，后台解析，主线程只提交合并后的 UI 状态。
- assistant delta 合并后按 50-120ms 节流刷新。
- command/log delta 按 100-200ms 批量写入，保留尾部窗口，默认不渲染完整历史。
- diff 更新按文件和 patch identity 去重，长 diff 默认折叠或虚拟化。
- 对话列表使用稳定 id，避免每个 delta 重建全部消息。
- 输入框使用局部 `@State`，发送时才进入全局 Store。
- 日志、diff、消息各自有内存上限和降级提示。
- XCTest 增加大输出、长消息、快速输入的性能用例。
- 可见日志按行级 `LazyVStack` 渲染，不使用单个超长 `Text` 渲染完整日志。
- 活跃 session 的日志、transcript、diff 缓存总量默认控制在 10-20MB 内。
- 主线程单帧输入路径目标控制在 8ms 内；持续输出时日志 UI 最多 8-10Hz，对话 UI 最多 1-2Hz。
- 自动滚动只在用户接近底部时触发，并避免每个 delta 都带动画滚动。
- 聊天气泡使用稳定 id 和轻量 row model；Markdown/代码块解析结果缓存到消息级别，主题切换只重绘可见消息。
- streaming assistant 使用前缀复用/尾部重解析策略，避免每次 delta 全量解析 Markdown。
- 对话 screen model 发布 snapshot，不让 View 直接观察完整 runtime model。
- 历史消息按页加载，首屏只加载最近一屏附近的数据。
- 新消息本地回显不等待完整 session reload。
- ThemeStore 只发布主题选择和 token 变化，不承载会话数据。
- 使用 Xcode 26 SwiftUI Performance Instrument 和 XCTest 基准验证长列表、滚动、输入和内存。

## Security Decisions

- `agentd` 是唯一可被 Tailscale 访问的服务。
- Codex app-server 默认走 stdio 子进程；socket 模式只能是 unix socket 或 loopback。
- Bearer Token 必填，长度校验保留。
- 默认禁用 query token，避免 URL、日志和 Referer 泄漏；WebSocket 使用 `Authorization` header。
- WebSocket 增加可配置 Host/Origin 校验，继续以 Bearer Token 为主边界。
- 项目 allowlist 仍是工作目录边界。
- 移动端不能传任意 cwd，只能传 `project_id`。
- 审批请求必须结构化展示，默认不自动批准高危命令或文件变更。
- 审批超时、客户端断开或未知 request type 时默认拒绝。
- 远程入口固定安全 sandbox/approval 策略，禁止从移动端启用 `dangerFullAccess` 或 `approvalPolicy=never`。
- 展示 token usage 和 rate limit 状态，便于控制成本和排查配额问题。
- doctor 不输出 token、socket secret、完整敏感环境变量。

## Migration Plan

1. 增加 `CodexAppServerRuntime` spike，基于 `stdio://` 跑通 initialize/list/start/turn。
2. 在 `agentd` 内并存 PTY 和 app-server runtime，通过 `AGENTD_RUNTIME` 控制。
3. API 兼容当前 iOS App，先把内部数据源换成 app-server thread。
4. iOS 改为消费结构化 `assistant_delta`、`log_delta`、`diff_updated`、`approval_request`。
5. 落地 session/message/event 数据流和分页读取。
6. 引入 iOS/iPadOS 26 Liquid Glass UI、微信式对话体验和主题系统。
7. 增加性能和端到端测试。
8. app-server runtime 稳定后，把 PTY runtime 降为 debug fallback。

## Risks / Trade-offs

- [Risk] Codex app-server 仍是 experimental → 用 `agentd` 封装协议，减少 iOS 直接耦合。
- [Risk] 协议会随 Codex CLI 版本变化 → 每次开发用 `codex app-server generate-ts/json-schema` 做本机探测，runtime 按 capability 做兼容。
- [Risk] JSON-RPC 协议体量大 → 只实现 Codex-only 移动端需要的最小方法和事件。
- [Risk] 大输出仍可能拖慢客户端 → 明确节流、窗口化、虚拟化和内存上限。
- [Risk] 历史读取和实时事件双写导致数据乱序或重复 → 使用 `seq`、稳定 id、revision 和幂等 reducer。
- [Risk] 主题切换导致全量消息重建 → 使用语义 token 和可见窗口渲染，缓存消息解析结果。
- [Risk] 过度模仿 Litter 导致 scope 膨胀 → 只借鉴 dashboard、composer、timeline、theme、render cache；明确不做 Android/Rust/Watch/CarPlay/语音/小游戏。
- [Risk] GPL 代码污染 → 不复制 Litter 源码和资源，仅用公开仓库做交互与架构参考。
- [Risk] app-server 管理进程残留 → doctor 和 shutdown 需要覆盖子进程生命周期。
- [Risk] iOS 26 API 兼容性 → 新 UI 以 iOS/iPadOS 26 为目标，不为旧系统增加复杂兼容层。
