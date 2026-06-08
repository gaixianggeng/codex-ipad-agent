# CodexAgentPad

## 目标

`CodexAgentPad` 是原生 iPad SwiftUI 控制台，用来替代已删除的 Web/PWA 前端。目标主链路是 iPad App 直接消费 Codex app-server JSON-RPC 协议；Mac 上的 `agentd` 只负责项目 allowlist、鉴权、健康诊断、app-server 启动和可选薄网关。

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

已下线旧链路：`/api/sessions*`、`/api/sessions/{id}/ws`、Web/PWA 和 iOS PTY 文本解析回退都已经删除。后续不要再基于这些入口增加功能。

目标体验按 iOS/iPadOS 26 推进，`project.yml` 的 deployment target 为 iOS 26.0。MVP 不在 iPad 上运行 Codex，也不做 Mac 自动发现。用户先在 Mac 上执行：

```bash
codex --version
codex app-server --help

agentd setup
agentd doctor --check-port
brew services start codex-ipad-agent
agentd doctor
agentd pair
```

然后在设置页手动输入或导入配对链接：

- Endpoint，例如 `http://100.127.16.9:8787`
- Token，也就是 `AGENTD_TOKEN`
- 配对链接，例如 `codexagentpad://pair?endpoint=...&token=...`

Token 存入 Keychain，Endpoint 存入 UserDefaults。客户端固定使用直连模式，旧版本保存过的兼容模式配置会在启动时自动清理。

direct 模式下，iPad 仍只连接 `agentd`，不会直接保存 app-server upstream token。`agentd setup` 会生成独立 upstream token file；Mac 侧由 `agentd` 读取并注入上游 `Authorization`，iPad 不接触这个 token。

直连要求：

1. 推荐用 `agentd setup` 生成配置；`agentd serve` 会在 `app_server.managed=true` 时自动托管 loopback `codex app-server`。
2. 设置页点击“测试连接”，会校验 `/api/app-server/config` 和 gateway 可用性。
3. 点击“保存并加载”会断开旧 WebSocket，重新创建 direct API client 和 WebSocket client。

## 实现

目录结构：

```text
Sources/
  Core/API              agentd control-plane 和 app-server JSON-RPC 客户端
  Core/Models           app-server / agentd control-plane JSON 模型
  Core/Parsing          历史文本解析与 Markdown 渲染辅助
  Core/Security         Keychain TokenStore
  State                 AppStore / SessionStore / SessionIndexStore / MessageStore / EventReducer / LogStore
  Features              设置、项目、会话、对话、日志、诊断视图
```

关键性能约束：

- 输入框只维护本地 `ComposerState`，不触发日志刷新。
- direct 模式由 Swift JSON-RPC client 处理 app-server request/response、notification 和 server request。
- app-server 事件先投影成内部 `AgentEvent`，再由 `EventReducer` 分发给消息层和日志层；`SessionStore` 只协调低频 session 状态。
- `LogStore` 先批量合并 output，再以 120ms 节流刷新 UI；内部保留 120000 字符，界面渲染最近 80000 字符。
- app-server runtime 不依赖终端尺寸，不跟随移动端键盘或布局变化频繁发送 resize。
- direct 模式不把终端文本作为主消息来源；消息以 app-server 结构化事件为准。

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
  -scheme CodexAgentPad \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

测试 target 编译：

```bash
xcodebuild \
  -project ios/CodexAgentPad/CodexAgentPad.xcodeproj \
  -scheme CodexAgentPad \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  clean build-for-testing
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
- 设置页固定使用 direct 模式，保存后不复用旧 WebSocket。
- 能在设置页切换外观模式、主题预设、UI 字体、代码字体和字体大小，主工作台立即生效并在重启后保持。

外观验收：

- 外观模式支持 `系统`、`浅色`、`深色`；系统模式跟随当前设备外观，手动浅色/深色不跟随系统变化。
- 主题预设先支持 `Codex`、`Xcode`、`Gruvbox`，覆盖聊天背景、气泡、代码块、侧栏选中态、日志和 Inspector 常用面板。
- 字体设置支持 UI 字体、代码字体和 85%-135% 字体大小；超出范围会自动 clamp。
- 外观设置只写入本机 `UserDefaults`，不触发连接重置，不影响 Endpoint、Token、会话、日志和 app-server runtime。

性能验收：

- 输入框连续输入 200-500 字，右侧日志不应随每个按键刷新。
- WebSocket 持续输出时，输入框仍可编辑。
- 日志超过 120000 字符后只保留尾部。
- 大段终端输出时 CPU 不应长期高占用，优先用 Instruments 的 Time Profiler 和 Allocations 看 `LogStore`、`ConversationStore`。
- 真机优先验收，Simulator 只能做辅助。

## 风险与优化

当前限制：

- 只支持单个后端配置。
- direct 模式仍需要 app-server WebSocket transport 或 agentd 薄网关。
- 每个 session 当前只允许一个 iOS WebSocket attach。
- app-server runtime 走结构化事件；iOS 不再用 PTY/TUI 文本启发式解析消息气泡。
- 当前后端是 HTTP，App 通过 ATS 例外访问，仅建议本机或 Tailscale 使用。

后续优化：

- 多 Mac 配置。
- 会话搜索。
- 日志导出。
- Instruments 基准脚本和 XCTest UI 自动化。
