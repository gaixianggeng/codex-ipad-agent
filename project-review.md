# Mimi Remote 项目整体评估报告

> 评估日期：2026-07-05
> 评估范围：全仓库代码 + 架构 + 安全 + 测试 + 文档 + 工程化
> 评估方式：只读审查，不修改任何代码

## 一、项目概要

**Mimi Remote** 是一个"iPad/iPhone 原生 App + Mac 本机 Go 网关"的远程开发控制台。iPad 端通过 WebSocket 直连 Mac 上运行的 `agentd`，再由 `agentd` 转发到本机 Codex app-server 的 JSON-RPC 协议，实现"在 iPad 上操作 Mac 本机开发环境"。

核心架构为三层：

```
iPad SwiftUI App  ──WebSocket + JSON-RPC──▶  agentd (Go 薄网关)  ──loopback ws──▶  codex app-server
```

## 二、代码规模

| 维度 | Go 后端 | Swift 前端 |
|------|---------|-----------|
| 源码行数 | ~16,500 行 / 30 文件 | ~35,700 行 / 40 文件 |
| 测试行数 | ~10,700 行 / 22 文件 | ~16,800 行 / 7 文件 |
| 测试/源码比 | ~65% | ~47% |
| 外部依赖 | 3 个（pty、websocket、qrcode） | 2 个（swift-markdown、swift-snapshot-testing） |

## 三、分维度评估

### 1. 安全设计 — 9.5/10

这是全项目最亮的部分，安全意识贯穿每一层：

- **Token 隔离**：外侧（iPad→agentd）和内侧（agentd→app-server）使用独立 Token，不复用
- **常量时间比较**：`subtle.ConstantTimeCompare` 防止时序攻击
- **Bearer Header 优先**：默认拒绝 URL query token，避免出现在日志/Referer/浏览器历史
- **短期配对票据**：QR 码只承载短期签名票据，不包含长期 Token；兑换后才拿到真实凭证
- **路径 allowlist**：项目路径必须在配置 allowlist 内；browse_roots 有明确边界；symlink 不跨越授权范围
- **方法白名单**：gateway 对 JSON-RPC method 做白名单过滤（Codex 通道和 Claude 通道各有独立白名单）
- **审批 fail-closed**：超时、断线、未知类型一律拒绝
- **ATS 例外 + Endpoint 校验**：为 Tailscale 裸 IP 开了 ATS HTTP 例外，但 App 端先校验只允许本机/局域网/Tailscale/.ts.net/HTTPS
- **日志脱敏**：HTTP 日志对 token/access_token/authorization/pair_sig 做了 redaction
- **非交互式服务不打印 Token**：Homebrew service 模式检测到非 TTY 时不输出二维码和 Token

### 2. 架构清晰度 — 9.0/10

**核心决策非常正确**：agentd 做薄网关，不维护自定义业务协议，直接透传 app-server JSON-RPC。这把维护成本压到了最低。

**Go 后端**：
- 包划分清晰：config / auth / projects / doctor / setup / httpapi / appserver / session / codexhistory / ring
- CLI 命令设计合理：up / setup / start / restart / status / logs / pair / doctor / serve / version
- `agentd doctor --fix` 自愈机制是加分项
- 托管 app-server 子进程的生命周期管理完善（启动、健康检查、退出诊断、资源回收）

**Swift 前端**：
- Store 模式（AppStore / SessionStore / ConversationStore / LogStore / SessionContextStore / ThemeStore）
- `EventReducer` 用 actor 实现线程安全的事件归并，设计成熟
- 协议抽象到位：`SessionStoreAPIClient` / `SessionWebSocketClient` / `CodexAppServerTransport`，便于测试替身
- Feature-based 目录结构：Conversation / Settings / Inspector / Projects / Sessions / Logs / Diagnostics
- 纯 SwiftUI，无 WebView，符合移动端原生体验目标

**iOS 端事件流设计**值得关注：app-server 原始事件 → `AgentEvent` 投影 → `EventReducer`（actor）归并 → 分发到各 Store。这个管道对乱序事件、审批/输入卡清除、foreground 活动管理都有明确的状态机处理。

### 3. 文档完备度 — 9.5/10

对于一个个人项目来说，文档质量**异常高**：

- README 覆盖架构、安全边界、安装、使用、API 示例、风险——接近生产级
- CONTRIBUTING.md 有明确代码要求和 PR 自查清单
- SECURITY.md 有清晰的支持范围和安全边界
- NOTICE.md 有 IP/品牌边界声明
- docs/ 下 11 篇文档涵盖 Markdown 渲染设计、发布计划、VPS 运维、隐私政策、品牌策略、开源发布流程等
- openspec/ 有变更管理规范
- 代码内中文注释说明了关键设计原因（如"实时事件可能乱序"的审批清除逻辑）

### 4. 测试覆盖 — 7.5/10

**Go 端**覆盖较好：22 个测试文件覆盖 auth、config、doctor、projects、ring、session、httpapi（router/directories/files/actions/voice/gateway/runtime）、appserver（client/managed/protocol/real_smoke）、codexhistory。

**Swift 端**有提升空间：7 个测试文件覆盖了核心逻辑（ConversationSnapshot、PairingLink、LogStore、ConversationDataFlow、CodexAppServerProtocol、MarkdownRendering、ThemeStore），但缺少对 Settings、Inspector、Projects、Sessions、Logs、Diagnostics 等 Feature 视图的独立测试。不过现有测试涵盖了最关键的协议解析和事件归并逻辑，优先级合理。

### 5. 工程化 — 8.5/10

- XcodeGen 管理工程文件，避免 xcodeproj 冲突
- GoReleaser + GitHub Actions 做 tag 触发的自动化发布
- Homebrew tap 分发，`brew install` 一键安装
- `agentd up` 一条命令完成配置 + 启动 + 配对二维码
- `scripts/deploy-ipad.sh` 无交互部署到真机
- .gitignore 完善，build 产物和 .pcm 文件未入库
- CI 流程包含 `go mod tidy` 检查和 `go test ./...`

## 四、值得注意的点

### 做得特别好的

1. **"薄网关"决策**——不自己造协议，只做鉴权 + 安全校验 + 转发，长期维护成本极低
2. **配对流程设计**——短期签名票据 + QR 码 + 兑换机制，安全性和用户体验兼顾
3. **doctor 自愈**——配置损坏时自动备份 + 重建，减少用户排障成本
4. **语音转写链路**——复用 Codex 登录态做 STT，个人开发者零额外成本
5. **Claude Code 实验通道**——通过 bridge 子进程接入，不侵入主架构，可独立开关

### 可以改进的

1. **project.yml 中硬编码了 DEVELOPMENT_TEAM**（`9HZ89R58PZ`）——CONTRIBUTING.md 要求 PR 检查是否泄漏 Team ID，但 project.yml 里就写着。其他贡献者构建时必须改这一行。建议改为环境变量或 xcconfig 注入。

2. **iOS 26.0 部署目标非常激进**——iOS 26 是极新版本，用户基数受限。如果是有意为之（只给自己用）则没问题；如果计划扩大用户群，建议考虑降到 iOS 18 或 17。

3. **Swift 测试文件偏少**——7 个测试文件 vs 40 个源文件。Go 端做到了 22:30，iOS 端可以考虑补充 Feature 层的 snapshot 测试。

4. **Claude bridge 生命周期**——per-connection 模型下，iPad 锁屏/切后台/断网都会杀掉 bridge，正在跑的 turn 会中断。README 已经明确标注了这个 v1 限制，但用户体验上可能需要更优雅的中断恢复。

5. **单用户单 Token**——MVP 限制，README 已明确。后续多用户需要重新设计认证和权限隔离。

6. **`.github/workflows/` 只有 release.yml**——没有 CI 的 PR 检查 workflow（如 lint、test、build 验证）。对于个人项目可以理解，但如果有外部贡献者参与，建议补充 PR 检查流程。

## 五、总评

| 维度 | 评分 |
|------|------|
| 安全设计 | 9.5 |
| 架构清晰 | 9.0 |
| 文档完备 | 9.5 |
| 测试覆盖 | 7.5 |
| 工程化 | 8.5 |
| **综合** | **8.6 / 10** |

**一句话结论**：作为一个个人开发者项目，Mimi Remote 的工程质量已经达到了**小型团队产品级**水准。架构决策（薄网关 + 原生直连）是正确的长期赌注，安全设计远超同类个人项目的平均水平，文档覆盖度甚至超过很多商业产品。主要短板在 iOS 端测试覆盖和部署目标过于激进，但这些都是可控的优化项，不影响整体架构的健壮性。

---

*本报告基于只读代码审查生成，未修改任何代码。*
