# CodexAgentPad

## 目标

`CodexAgentPad` 是原生 iPad SwiftUI 控制台，用来替代 Web/PWA 前端。Mac 仍然运行现有 `agentd`，iPad App 只负责项目、会话、对话、日志和输入交互。

## 方案

整体链路：

```text
iPad SwiftUI App
  -> REST: /api/projects /api/sessions /api/sessions/{id}/messages
  -> WebSocket: /api/sessions/{id}/ws
Mac agentd
  -> Codex app-server stdio runtime
  -> PTY fallback
```

目标体验按 iOS/iPadOS 26 推进，`project.yml` 的 deployment target 为 iOS 26.0。MVP 不在 iPad 上运行 Codex、不直连 Codex app-server，也不做 Mac 自动发现。用户在设置页手动输入：

- Endpoint，例如 `http://100.127.16.9:8787`
- Token，也就是 `AGENTD_TOKEN`

Token 存入 Keychain，Endpoint 存入 UserDefaults。

## 实现

目录结构：

```text
Sources/
  Core/API              REST 和 WebSocket 客户端
  Core/Models           agentd JSON 模型
  Core/Parsing          ANSI 清理和 Codex 输出解析
  Core/Security         Keychain TokenStore
  State                 AppStore / SessionStore / SessionIndexStore / MessageStore / EventReducer / LogStore
  Features              设置、项目、会话、对话、日志、诊断视图
```

关键性能约束：

- 输入框只维护本地 `ComposerState`，不触发日志刷新。
- WebSocket 事件由 `EventReducer` 分发给消息层和日志层；`SessionStore` 只协调低频 session 状态。
- `LogStore` 先批量合并 output，再以 120ms 节流刷新 UI；内部保留 120000 字符，界面渲染最近 80000 字符。
- app-server runtime 不依赖终端尺寸；PTY fallback 固定 `120x32`，不跟随 iPad 键盘或布局变化频繁发送 resize。
- ANSI 清洗和 parser 放在后台任务；对话解析延迟 700ms 合并输出，避免每个 output chunk 都刷新消息气泡。

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
- 能通过 WebSocket 接收 output。
- 能发送普通输入、Enter、Ctrl-C。
- 能停止 running session。

性能验收：

- 输入框连续输入 200-500 字，右侧日志不应随每个按键刷新。
- WebSocket 持续输出时，输入框仍可编辑。
- 日志超过 120000 字符后只保留尾部。
- 大段终端输出时 CPU 不应长期高占用，优先用 Instruments 的 Time Profiler 和 Allocations 看 `LogStore`、`ConversationStore`。
- 真机优先验收，Simulator 只能做辅助。

## 风险与优化

当前限制：

- 只支持单个后端配置。
- 同一个 session 后端只允许一个 WebSocket attach。
- app-server runtime 走结构化事件；PTY fallback 仍保留 TUI 文本启发式解析。
- 当前后端是 HTTP，App 通过 ATS 例外访问，仅建议本机或 Tailscale 使用。

后续优化：

- 多 Mac 配置。
- 会话搜索。
- 日志导出。
- Instruments 基准脚本和 XCTest UI 自动化。
