## 1. Codex App-Server Runtime Spike

- [ ] 1.1 生成并保存临时协议样例，确认 `initialize`、`thread/list`、`thread/start`、`thread/resume`、`thread/read`、`turn/start`、`turn/interrupt` 的请求/响应形状
- [ ] 1.2 实现最小 Go JSON-RPC stdio client，可连接 `codex app-server --listen stdio://`
- [ ] 1.3 实现 app-server 子进程管理：启动、initialize/initialized 握手、stderr 诊断、健康检查、退出清理
- [ ] 1.4 实现 request id 映射、notification 分发、server request 分发和事件背压策略
- [ ] 1.5 跑通本机 smoke：列出 thread、在 allowlist 项目中启动 thread、发送一个 turn、接收 assistant delta

## 2. Backend Runtime Refactor

- [ ] 2.1 抽象 `Runtime` 接口，保留 `PTYRuntime` 作为 fallback
- [ ] 2.2 新增 `CodexAppServerRuntime`，映射 Codex thread/turn 到现有 session API
- [ ] 2.3 扩展配置：`AGENTD_RUNTIME`、app-server transport、managed process、fallback 开关
- [ ] 2.4 调整 `/api/sessions`、`/api/sessions/{id}`、`/api/sessions/{id}/messages` 使用 runtime 接口
- [ ] 2.5 调整 session WebSocket：输出结构化 `assistant_delta`、`log_delta`、`diff_updated`、`approval_request`、`turn_completed`
- [ ] 2.6 新增 Codex token usage、rate limit、active turn 状态字段，并兼容旧 iOS 客户端
- [ ] 2.7 doctor 增加 app-server runtime 检查，不泄漏 token、socket secret 或敏感环境变量

## 3. Session Data Flow

- [x] 3.1 定义轻量 `SessionRow`、分页 `MessagePage`、实时 `AgentEvent`、本地 `ComposerDraft` 数据模型
- [ ] 3.2 调整 `GET /api/sessions` 支持按 `project_id`、`cursor`、`limit` 返回轻量历史会话索引
- [ ] 3.3 调整 `GET /api/sessions/{id}/messages` 支持 cursor 分页，不一次性读取完整长会话
- [ ] 3.4 为 WebSocket 事件增加 `seq`、`session_id`、`turn_id`、`item_id`、`revision`，保证重连和重复事件可幂等归并
- [ ] 3.5 新建会话流程支持 `client_message_id`，iOS 先本地回显用户消息，后端确认后合并状态
- [ ] 3.6 iOS 拆分 `SessionIndexStore`、`MessageStore`、`EventReducer`、`ComposerState`，避免全局 Store 承载所有高频状态
- [ ] 3.7 增加断线重连流程：读取 session snapshot，按 `last_seen_seq` 或消息 cursor 恢复可见状态

## 4. iOS / iPadOS 26 UI Refactor

- [x] 4.1 建立 Litter iOS 参考清单，明确借鉴点和禁止复制 GPL 代码/资源的边界
- [ ] 4.2 将 App 目标体验改为 iOS/iPadOS 26，确认 project.yml 和 README 中的版本约束
- [ ] 4.3 用 `NavigationSplitView` 重构主界面：sidebar 为项目，content 为会话，detail 为当前工作区和对话
- [ ] 4.4 参考 Litter dashboard，实现最近会话、状态点、预览、pending approval、active turn、新建入口
- [ ] 4.5 将日志从 detail 第三列迁移到 `.inspector`，实现日志、diff、审批、诊断分区
- [ ] 4.6 使用系统 toolbar、toolbar 分组和 Liquid Glass 控制层，避免自绘重型壳
- [ ] 4.7 实现底部 glass composer，输入状态局部化，发送后再进入全局 Store
- [ ] 4.8 参考 Litter composer，实现 send/stop、长 prompt 展开、approval/cost/context chips
- [ ] 4.9 新增 `WorkspaceView`、`ConversationTimelineView`、`ConversationScreenModel`、`SessionInspectorView`、`LogTailView`、`DiffPanelView`、`ApprovalCardView`
- [ ] 4.10 实现微信式对话体验：气泡、发送状态、底部锚定、上滑加载历史、新消息提示、长按菜单
- [ ] 4.11 参考 Litter timeline，将 reasoning/command/tool/file change 显示为摘要卡片，完整内容进 Inspector
- [ ] 4.12 新增 `ThemeStore` 和语义主题 token，支持 system/light/dark/highContrast/自定义主题切换
- [ ] 4.13 参考 Litter Appearance 页面，实现主题选择、字体大小、聊天预览
- [ ] 4.14 移除以终端 parser 为主的 assistant 提取路径，改为消费结构化事件

## 5. Client Performance

- [ ] 5.1 将 `AgentWebSocketClient` 改造成线程安全的 `WebSocketConnection` actor + `AsyncStream<AgentEvent>`
- [ ] 5.2 新增 `TerminalStreamStore`/`EventReducer` actor，WebSocket 接收和事件解析移出主线程，只向主线程提交批处理结果
- [ ] 5.3 assistant delta 以稳定 message id 合并，50-120ms 节流刷新
- [ ] 5.4 日志流按 100-200ms 批量写入，保留尾部窗口并限制内存
- [ ] 5.5 `LogTailView` 使用行级 `LazyVStack` 渲染，避免单个超长 `Text`
- [ ] 5.6 diff 列表按文件去重，长 diff 默认折叠或分页渲染
- [ ] 5.7 输入框连续输入 500 字时不触发日志/对话大范围重渲染
- [ ] 5.8 将活跃 session 的日志、transcript、diff 缓存默认控制在 10-20MB 内
- [ ] 5.9 缓存消息级 Markdown/代码块解析结果，主题切换只重绘可见消息
- [ ] 5.10 实现 streaming assistant 前缀复用/尾部重解析缓存，避免每次 delta 全量解析 Markdown
- [ ] 5.11 为 timeline row 增加 render digest / Equatable row 策略，减少无关重绘
- [ ] 5.12 只有 Instruments 证明 SwiftUI 列表无法达标时，才评估 UIKit-backed list；MVP 不实现 Litter pinch zoom
- [ ] 5.13 增加性能 XCTest：大日志、大 assistant delta、长 diff、快速输入、主题切换、分页滚动
- [ ] 5.14 用 Xcode 26 SwiftUI Performance Instrument 验证主线程、滚动和内存热点

## 6. Security And Approval Flow

- [ ] 6.1 确保 Codex app-server 默认只通过 `stdio://` 子进程访问，socket 模式仅允许 unix socket 或 loopback
- [ ] 6.2 确保移动端仍只能提交 `project_id`，不能提交任意 cwd
- [ ] 6.3 实现 app-server 方法 allowlist，默认拒绝 `fs/*`、`command/exec`、`process/*`、`config/*write`、`plugin/*install`、`marketplace/*`、`remoteControl/*`
- [ ] 6.4 映射 Codex approval/server request 为 iOS 审批卡片，超时、断线或未知类型默认拒绝
- [ ] 6.5 默认不自动批准高危命令、文件变更、网络权限扩展，不允许移动端启用 `dangerFullAccess` 或 `approvalPolicy=never`
- [ ] 6.6 默认禁用 query token，WebSocket 使用 `Authorization` header，并增加 Host/Origin 校验配置
- [ ] 6.7 README 增加 Tailscale ACL、Token、app-server 本机监听、审批和成本控制说明

## 7. Verification And Migration

- [ ] 7.1 Go 单测覆盖 runtime 配置、initialize 握手、request id 映射、allowlist cwd 映射、事件映射、doctor
- [ ] 7.2 Go fake app-server contract test 覆盖 start/list/thread/turn、approval approve/decline、超时默认拒绝
- [ ] 7.3 Go API 测试覆盖 session list 分页、message 分页、new session、本地回显确认、断线恢复
- [ ] 7.4 Go 安全测试覆盖 query token 禁用、高风险方法拒绝、`dangerFullAccess`/`approvalPolicy=never` 拒绝
- [ ] 7.5 可选真实 Codex smoke：`initialize -> thread/start -> turn/start("只回复 ok") -> turn/completed -> token usage`
- [ ] 7.6 iOS XCTest 覆盖 Store 事件合并、日志窗口、diff 降级、approval model、composer 性能、主题切换
- [ ] 7.7 iOS snapshot/UI 测试覆盖 Litter-inspired dashboard、composer、timeline、Appearance 预览
- [x] 7.8 本机验证 `go test ./...` 和 `go build -o bin/agentd ./cmd/agentd`
- [ ] 7.9 iOS 模拟器验证 XCTest 和主要 UI 流程
- [ ] 7.10 更新中文 README、iOS README 和迁移说明
