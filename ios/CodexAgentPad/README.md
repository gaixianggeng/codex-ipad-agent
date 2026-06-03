# CodexAgentPad

## 目标

`CodexAgentPad` 是原生 iPad SwiftUI 控制台，用来替代 Web/PWA 前端。目标主链路是 iPad App 直接消费 Codex app-server JSON-RPC 协议；Mac 上的 `agentd` 只负责项目 allowlist、鉴权、健康诊断、app-server 启动和可选薄网关。

## 方案

整体链路：

```text
iPad SwiftUI App
  -> REST: /api/projects /api/app-server/config
  -> WebSocket: /api/app-server/ws
  -> Codex app-server JSON-RPC
Mac agentd control plane / thin gateway
  -> loopback codex app-server WebSocket upstream
```

兼容链路仍保留：

```text
iPad SwiftUI App / Web/PWA
  -> REST: /api/sessions
  -> WebSocket: /api/sessions/{id}/ws
Mac agentd compatibility runtime
  -> Codex app-server / PTY fallback
```

目标体验按 iOS/iPadOS 26 推进，`project.yml` 的 deployment target 为 iOS 26.0。MVP 不在 iPad 上运行 Codex，也不做 Mac 自动发现。用户在设置页手动输入：

- Endpoint，例如 `http://100.127.16.9:8787`
- Token，也就是 `AGENTD_TOKEN`
- 模式：`兼容模式` 走旧 `/api/sessions*`，`直连模式` 走 Codex app-server JSON-RPC

Token 存入 Keychain，Endpoint 和模式存入 UserDefaults。默认先保持兼容模式，启动 loopback app-server gateway 后再切到直连模式。

direct 模式下，iPad 仍只连接 `agentd`，不会直接保存 app-server upstream token。Mac 侧如果 app-server WS upstream 启用了 capability token，由 `agentd` 通过 `AGENTD_APP_SERVER_WS_TOKEN_FILE` 读取并注入上游 `Authorization`，iPad 不接触这个 token。

模式切换：

1. 直连模式需要 Mac 先运行 `codex app-server --listen ws://127.0.0.1:4222`，并让 `agentd` 配置 `AGENTD_APP_SERVER_LISTEN`。
2. 设置页选择 `直连模式` 后点击“测试连接”，会校验 `/api/app-server/config` 和 gateway 可用性。
3. 点击“保存并加载”会断开旧 WebSocket，重新按当前模式创建 API client 和 WebSocket client。
4. 如果 direct upstream 不稳定，切回 `兼容模式` 即可回滚到 `/api/sessions*`。

## 实现

目录结构：

```text
Sources/
  Core/API              agentd control-plane、app-server JSON-RPC 和兼容 WebSocket 客户端
  Core/Models           app-server / agentd 兼容 JSON 模型
  Core/Parsing          兼容 PTY 的 ANSI 清理和 Codex 输出解析
  Core/Security         Keychain TokenStore
  State                 AppStore / SessionStore / SessionIndexStore / MessageStore / EventReducer / LogStore
  Features              设置、项目、会话、对话、日志、诊断视图
```

关键性能约束：

- 输入框只维护本地 `ComposerState`，不触发日志刷新。
- direct 模式由 Swift JSON-RPC client 处理 app-server request/response、notification 和 server request。
- app-server 事件先投影成内部 `AgentEvent`，再由 `EventReducer` 分发给消息层和日志层；`SessionStore` 只协调低频 session 状态。
- `LogStore` 先批量合并 output，再以 120ms 节流刷新 UI；内部保留 120000 字符，界面渲染最近 80000 字符。
- app-server runtime 不依赖终端尺寸；兼容 PTY fallback 固定 `120x32`，不跟随 iPad 键盘或布局变化频繁发送 resize。
- ANSI 清洗和 parser 只服务兼容回退路径；direct 模式不把终端文本作为主消息来源。

## 构建

生成 Xcode 工程：

```bash
cd /Users/gaixiaotongxue/code/codex-ipad-agent
xcodegen generate --spec ios/CodexAgentPad/project.yml --project ios/CodexAgentPad
```

命令行验证 Swift 代码可编译：

```bash
xcodebuild \
  -project ios/CodexAgentPad/CodexAgentPad.xcodeproj \
  -target CodexAgentPad \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

测试 target 编译：

```bash
xcodebuild \
  -project ios/CodexAgentPad/CodexAgentPad.xcodeproj \
  -target CodexAgentPadTests \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

真机运行：

1. 用 Xcode 打开 `ios/CodexAgentPad/CodexAgentPad.xcodeproj`。
2. 选择 `CodexAgentPad` scheme。
3. 选择 iPad 真机。
4. 设置开发者 Team 和签名。
5. Run。

## 验收

基础验收：

- 能保存 Endpoint + Token。
- 能测试连接并显示 agentd 版本。
- 能拉取项目列表和会话列表。
- 能选择 Codex 历史会话并加载历史消息。
- 能新建会话和继续历史会话。
- direct 模式能完成 `initialize -> thread/start -> turn/start`。
- 能通过 app-server notification 接收 assistant delta、completed item、日志、diff、turn completed。
- 能发送普通输入、Ctrl-C/interrupt 和审批响应。
- 能停止 running session。
- 能从设置页切换 direct / 兼容模式，保存后不复用旧 WebSocket。

性能验收：

- 输入框连续输入 200-500 字，右侧日志不应随每个按键刷新。
- WebSocket 持续输出时，输入框仍可编辑。
- 日志超过 120000 字符后只保留尾部。
- 大段终端输出时 CPU 不应长期高占用，优先用 Instruments 的 Time Profiler 和 Allocations 看 `LogStore`、`ConversationStore`。
- 真机优先验收，Simulator 只能做辅助。

## 风险与优化

当前限制：

- 只支持单个后端配置。
- direct 模式仍需要 app-server WebSocket transport 或 agentd 薄网关；兼容 managed stdio 连接不能直接当 raw gateway 复用。
- 兼容 session 后端仍只允许一个 WebSocket attach。
- app-server runtime 走结构化事件；兼容 PTY fallback 仍保留 TUI 文本启发式解析。
- 当前后端是 HTTP，App 通过 ATS 例外访问，仅建议本机或 Tailscale 使用。

后续优化：

- 多 Mac 配置。
- 会话搜索。
- 日志导出。
- Instruments 基准脚本和 XCTest UI 自动化。
