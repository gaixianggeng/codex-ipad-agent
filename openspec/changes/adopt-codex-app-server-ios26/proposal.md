## Why

当前 `agentd` 通过 PTY 启动 `codex --no-alt-screen`，再把终端输出转给 iPad。这个方案已经能跑，但长期问题很明确：

- 终端文本和 ANSI 输出不是稳定协议，assistant 回复、命令日志、diff、审批状态都需要启发式解析。
- iPad 客户端会被大段终端输出拖累，输入框和滚动体验容易卡。
- Codex CLI 已经提供 experimental `app-server`，支持 `thread/start`、`thread/resume`、`turn/start`、结构化事件和官方移动端更接近的运行模型。
- Litter 的方向验证了移动端围绕 Codex app-server 做结构化连接是更稳的路线，但本项目不需要复制它的 Rust + UniFFI + Android + 多 Agent 复杂架构。

因此需要把项目从“PTY 终端桥”调整为“轻量 iOS/iPadOS Codex app-server 网关”。

## What Changes

- `agentd` 保留为 Mac 上的单机网关，继续负责 Tailscale 访问、Bearer Token、项目 allowlist、doctor 和稳定移动端 API。
- 新增 Codex app-server runtime，默认由 `agentd` 管理 `codex app-server --listen stdio://` 子进程；后续可选 `unix://`，`ws://127.0.0.1` 仅作为本机调试路径。
- iOS/iPadOS App 继续只连接 `agentd`，不直接实现完整 Codex app-server 协议，避免 experimental 协议变化直接影响客户端。
- `agentd` 做受控网关，不做 Codex app-server 全量透明代理：只开放移动端需要的 thread/turn、审批、成本和诊断能力。
- 历史会话读取、会话列表展示、新建会话、实时对话流采用清晰的数据流和归一化状态模型，避免后续 Store 混乱和重复渲染。
- App UI 按 iOS/iPadOS 26 Liquid Glass 设计模型重构，并参考 Litter iOS 的移动端交互节奏：dashboard、会话卡片、聊天 timeline、底部 composer、外观设置。
- 对话展示尽量靠近微信体验：即时本地回显、底部锚定、旧消息分页加载、消息状态清晰、滚动和键盘体验稳定。
- App 支持主题切换，通过语义化主题 token 控制颜色、气泡、代码块和控制层外观。
- 客户端性能作为硬约束：高频事件、大日志、diff、审批更新不能阻塞输入和主线程。
- 只支持 Codex。暂不支持 Android、Claude、OpenCode、Pi、本地手机运行时、Watch、CarPlay、语音等扩展能力。

## Capabilities

### New Capabilities

- `codex-app-server-runtime`: 使用 Codex app-server 作为默认运行时，覆盖 thread/turn 生命周期、结构化事件映射、进程管理和 PTY fallback。
- `ios26-mobile-client`: iOS/iPadOS 26 原生 Codex 移动端体验，覆盖 Liquid Glass 信息架构、会话/对话/日志/审批工作流。
- `mobile-performance`: 客户端性能保障，覆盖输入响应、WebSocket 事件节流、日志和 diff 渲染、内存上限、测试指标。
- `codex-mobile-security`: Codex-only 移动网关安全边界，覆盖本机 app-server、方法 allowlist、cwd allowlist、审批默认拒绝、Token 和成本观测。
- `session-data-flow`: 会话索引、历史消息分页、新建会话、WebSocket 事件、断线重连和本地状态归一化的数据流。
- `chat-experience`: 微信式对话阅读和输入体验，覆盖消息气泡、发送状态、底部锚定、分页加载、复制/重试和流式输出。
- `theme-system`: iOS/iPadOS 26 下的主题系统，覆盖系统/浅色/深色/高对比主题、语义 token、持久化和性能边界。
- `litter-inspired-ios-reference`: 将 Litter iOS 的优秀交互和性能设计转化为本项目的轻量参考规范，同时明确不复制 GPL 代码、不引入多平台重架构。

### Modified Capabilities

- `single-machine-console`: 从 PTY-backed Codex session 迁移到 app-server-backed Codex thread，但保留 `agentd` 单进程和 API 网关定位。
- `tailscale-access`: 继续只暴露 `agentd`，Codex app-server 默认只走 stdio 子进程；如启用 socket 也只能是 unix socket 或 loopback 本机调试。

## Impact

- 后端新增 Codex app-server JSON-RPC stdio client、事件分发器和 runtime 抽象。
- 后端 session 模型需要映射到 Codex thread/turn 模型。
- iOS App 的对话数据源从终端 parser 切换到结构化事件，并按 session/message/event 归一化存储。
- iOS App 需要新增 theme store 和语义化颜色/字体/气泡 token。
- iOS 页面设计需要新增 Litter reference checklist，作为实现和验收时的 UI/UX 对照。
- Web/PWA 可以保留为调试入口，但主体验转向 iOS/iPadOS App。
- 需要更新 README、iOS README、doctor、Go 测试、iOS XCTest 和端到端 smoke。

## Non-Goals

- 不做 Android。
- 不支持 Claude、OpenCode、Pi 或任意多 Agent provider。
- 不把 Litter 的 Rust core/UniFFI 架构引入本项目。
- 不复制 Litter 的 GPL 源码、资源、品牌或非必要复杂交互，只借鉴产品体验和架构思想。
- 不让 iPad 直接连接 Codex app-server。
- 不做公网 relay、多用户 OAuth、RBAC。
- 不在 iPad 本地运行 Codex。
