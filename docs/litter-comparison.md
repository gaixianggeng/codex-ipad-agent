# 与 Litter 的能力对照与取舍

更新日期：2026-07-13
本地对照仓库审计基线：[Litter](https://github.com/dnakov/litter) commit `abee3ace6842`

## 目标

对照 Litter 当前实现，识别 Mimi Remote 真正值得补齐的 P0/P1 能力，同时保持“单机可运行、低维护成本、用户自有 Mac、明确远程权限边界”的产品方向。这个对照只用于功能和架构决策，不复制 Litter 源码。

## 方案

- 第一版继续采用 `iPhone / iPad -> Tailscale -> agentd -> Codex app-server`，不引入 Rust Core、Codex fork 或 SSH 控制面。
- 先补会影响安装、连接、恢复和高频开发闭环的能力，再考虑平台扩张和展示型功能。
- Litter 与 Mimi Remote 均使用 GPLv3 并附 App Store / Google Play 分发许可。即使协议兼容，仍默认采用独立实现；如确需复用代码，必须保留原作者版权、许可证和修改说明。

## 实现对照

| 维度 | Mimi Remote | Litter 基线 | 结论 |
| --- | --- | --- | --- |
| 电脑接入 | 安装 `agentd`，运行 `agentd up`，通过短期二维码把 Tailscale Endpoint 和外侧 Token 配对到 App | 支持本地/远端 server discovery、直连与 SSH 后再端口转发 | Mimi 首次路径更窄、更容易解释；Litter 在多电脑发现和切换上更完整 |
| 运行时架构 | Go 薄网关转发本机官方 Codex app-server，协议 allowlist 和 cwd 授权放在网关 | Swift/Kotlin UI + Rust 共享核心，包含 Codex submodule 和移动端 patch | Mimi 依赖少、升级和排障成本低；Litter 跨平台复用更强但构建链明显更重 |
| 远程安全 | 外侧 Bearer Token、独立 loopback upstream Token、项目/browse/worktree 边界、反向 RPC fail-closed | 主要通过本机运行时、远端 server 或 SSH 凭据/主机信任建立连接 | 两者信任模型不同；Mimi 的目标是让远程写操作继续经过 agentd 的细粒度约束 |
| 多服务器 | 可保存并重命名多台 Mac 的本地档案，每台使用独立 Keychain Token；验证并提交成功后才单活切换 | `SavedServer` / `SavedServerStore` 可记忆、重命名和重连多台 server，并按连接模式保存偏好 | Mimi 已补齐保存、重命名、手动切换、删除和重新配对 MVP；Bonjour/SSH discovery 继续后置 |
| 会话与项目 | 项目 allowlist、历史恢复、目标、Review、fork、archive、本地 pin、协议漂移门禁 | 多 server 会话、跨 server 入口和更宽的移动运行时能力 | Mimi 的单 server 会话闭环已够第一版；多 Mac profile 比继续扩 app-server 方法优先 |
| Worktree / Git | managed Worktree 创建、分支、fork、受保护删除和人工清理；文件/hunk stage、revert、commit、push、草稿 PR | 当前仓库更侧重多端运行时、server discovery、终端和移动系统集成 | Worktree 生命周期、安全清理和受控 Git 写操作是 Mimi 的差异化优势 |
| 命令执行 | 只允许配置中的 action，带确认、超时、输出截断和队列 | 有 SSH/终端相关界面与运行时 | Mimi 不应为“功能对齐”开放任意 Shell；allowlist action 继续作为 P1 边界 |
| 语音 | 录音经 agentd 复用 Codex 登录态转写，生成草稿后由用户确认发送 | 支持 Realtime Voice/WebRTC，并延伸到 Watch、CarPlay 等场景 | Codex 非公开转写接口存在兼容风险；先保证普通语音输入稳定，不引入 Realtime Voice 的额外维护面 |
| 移动系统体验 | 前台运行态通知、本地提醒、iPhone/iPad 自适应 | 另有 Live Activity、Watch、Widget、CarPlay、PiP 和更深通知链路 | Live Activity/通知深链可列 P2；Watch、CarPlay、PiP 不进入当前 P0/P1 |
| Artifact / 生成式 UI | 安全文件读取、图片/PDF 等交给 QuickLook；回复路径可点击 | 有 Dynamic Tools、Generative UI、图片生成结果和更丰富的展示组件 | Mimi 先补常见图片/PDF 轻预览；不建设通用前端运行时 |
| 平台 | 原生 iPhone / iPad | iOS、Android，并包含 watchOS 等目标 | Android 是产品扩张，不是第一版发布阻断；没有真实用户需求前不复制双端核心 |
| 部署与运维 | `doctor`、`healthz/readyz`、relay diagnostics、Homebrew、Linux user-systemd、升级/回滚文档 | 以移动 App、远端 discovery/SSH 和多平台构建发布为主 | 用户需要自行搭服务时，Mimi 的可运维链路更完整，必须继续保持这一优势 |

## P0 / P1 落地顺序

### P0：公开发布前

1. 已完成 HTTP JSON 请求体分级上限：无需 Bearer Token 的 `/api/pair/claim` 使用小限额，语音接口保留独立大限额。
2. 已完成动态 `/api/readyz`：Codex app-server upstream 必须完成带 capability Token 的 WebSocket 握手，不再只依赖静态进程检查。
3. 完成 GitHub 仓库、Homebrew Tap、Release Secret 和真实 CI；这些属于外部状态，不能用本地测试替代。
4. 在实体 iPad 上完成配对、前后台、Wi-Fi/蜂窝切换和 Tailscale 暂停/恢复验收。

### P1：本轮已完成

1. 多 Mac 连接档案包含显示名称、规范化 Endpoint、独立 Keychain Token、最近成功时间；同一时刻只连接一台 Mac。
2. 切换固定为先读取和验证目标档案，再提交 Keychain/元数据，最后断开旧 WebSocket；失败时完整保留旧会话和消息。
3. 已支持新增时命名、已有档案重命名、删除和重新配对；重命名只更新非敏感显示名称，不读取 Token 或重建连接。当前档案不能走普通删除，退出连接使用 Keychain-first 的清除配对事务。
4. 局域网发现仍待真实使用反馈。若后续需要，优先考虑 agentd 发布最小 Bonjour 元数据，不在 App 内引入 SSH 密钥和主机信任管理。

### 暂不跟进

- 在移动端 vendoring/fork Codex 或引入共享 Rust Core；
- 任意 SSH 终端、任意 Shell；
- Watch、CarPlay、PiP、Realtime Voice；
- Android、Cloud relay、Generative UI 通用运行时；
- 为多 server 同时在线增加复杂连接池。

## 风险与优化

- Litter 是快速演进中的独立项目，本表只代表上述 commit 的本地代码事实；升级优先级不能依赖一次性印象，应在下一次大版本规划前重新审计。
- “功能存在”不等于适合 Mimi。SSH、Realtime Voice、Watch 和多端共享核心会显著扩大权限、依赖和测试矩阵。
- 多 Mac 档案已经从单 endpoint 模型迁移为“UserDefaults 非敏感元数据 + 每档案独立 Keychain account”；迁移、切换或删除失败时必须继续保持 Keychain-first 的旧连接保留语义，不能把 Token 写入 UserDefaults。
- 协议兼容不等于可以无归属复制。任何需要复用源码的需求都必须先确认来源、保留版权与许可证声明，并明确记录修改；默认仍做独立实现。
