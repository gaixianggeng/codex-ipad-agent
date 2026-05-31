# Codex iPad Agent

## 目标

在 Mac 上启动一个单机 `agentd` 服务，让 iPad 通过原生 App 或 Web/PWA 连接 Tailscale 地址，选择本机项目并远程启动 Codex。核心目标是替代“每个项目都要手动运行一个服务”的体验。

## 方案

架构很简单：

```text
iPad 原生 App / Safari
  |
  | Tailscale HTTP/WebSocket
  v
Mac agentd
  |
  +-- Web UI
  +-- REST API
  +-- WebSocket
  +-- PTY -> codex --no-alt-screen
```

安全边界：

- `agentd` 运行在开发机本地，Codex 凭证不离开开发机。
- Web 端只能选择配置中的项目 ID，不能传任意路径。
- API 和 WebSocket 都需要 Bearer Token。
- MVP 不建议公网暴露，只建议本机或 Tailscale 使用。

## 实现

### 1. 构建

```bash
cd /Users/gaixiaotongxue/code/codex-ipad-agent
go build -o bin/agentd ./cmd/agentd
```

### 1.1 构建原生 iPad App

原生 App 工程位于：

```text
ios/CodexAgentPad
```

先用 XcodeGen 生成 Xcode 工程：

```bash
cd /Users/gaixiaotongxue/code/codex-ipad-agent/ios/CodexAgentPad
xcodegen generate
```

本机命令行可先编译 iPhoneOS target，验证 Swift 代码是否通过：

```bash
xcodebuild \
  -project CodexAgentPad.xcodeproj \
  -target CodexAgentPad \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

测试 target 编译：

```bash
xcodebuild \
  -project CodexAgentPad.xcodeproj \
  -target CodexAgentPadTests \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

模拟器运行：

```bash
xcodebuild \
  -project CodexAgentPad.xcodeproj \
  -scheme CodexAgentPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  clean build
```

如果本机没有这个模拟器，可以先查看可用设备：

```bash
xcodebuild -showdestinations \
  -project CodexAgentPad.xcodeproj \
  -scheme CodexAgentPad
```

App 首次启动会进入设置页：

- Endpoint：例如 `http://127.0.0.1:8787` 或 `http://100.127.16.9:8787`
- Token：`AGENTD_TOKEN`

Token 使用 iOS Keychain 保存，Endpoint 使用 UserDefaults 保存。MVP 为了支持本机/Tailscale HTTP，App 已开启 ATS HTTP 例外；不要把 agentd 暴露到公网。

App 端设计边界：

- SwiftUI 原生实现，不使用 WebView。
- 输入框、会话状态、对话解析、终端日志四块分离。
- WebSocket output 在 Store 层同时分发给 `ConversationStore` 和 `LogStore`。
- 日志有节流和最大缓冲，输入框连续输入不会触发日志刷新。
- ANSI 清洗和对话 parser 放在后台任务，主线程只做轻量状态更新。
- 第一版固定终端尺寸 `120x32`，不跟随键盘或布局变化频繁发送 resize。

### 2. 本机启动

推荐用环境变量启动，避免把真实 Token 写进配置文件：

```bash
export AGENTD_TOKEN="$(openssl rand -hex 32)"
export AGENTD_SCAN_ROOTS="/Users/gaixiaotongxue/code"

./bin/agentd serve
```

本机打开：

```text
http://127.0.0.1:8787
```

页面里输入 `AGENTD_TOKEN` 后连接。

### 3. Tailscale 启动

Mac 和 iPad 先登录同一个 tailnet。

```bash
tailscale status
tailscale ip -4
```

绑定 Mac 的 Tailscale IP：

```bash
export MAC_TS_IP="$(tailscale ip -4)"
export AGENTD_TOKEN="$(openssl rand -hex 32)"
export AGENTD_SCAN_ROOTS="/Users/gaixiaotongxue/code"

AGENTD_BIND="$MAC_TS_IP" \
AGENTD_PORT=8787 \
./bin/agentd serve
```

iPad Safari 打开：

```text
http://<Mac 的 Tailscale IP>:8787
```

如果使用 MagicDNS，也可以打开：

```text
http://<mac-hostname>.<tailnet-name>.ts.net:8787
```

### 3.1 安装成 iPad PWA

项目已经内置 PWA 文件：

```text
/manifest.webmanifest
/sw.js
/icons/icon.svg
```

iPad 上推荐用 HTTPS 访问后添加到主屏幕：

```text
Safari -> 分享 -> 添加到主屏幕
```

注意：service worker 通常要求 HTTPS 或 localhost。直接访问 `http://100.x.x.x:8787` 时页面仍能正常用，但 PWA 离线缓存可能不会启用。后续可以用 Tailscale HTTPS/MagicDNS 或 `tailscale serve` 提供 HTTPS 入口。

### 4. 使用配置文件

复制示例：

```bash
cp config.example.json config.json
```

编辑 `config.json` 后启动：

```bash
AGENTD_TOKEN="$(openssl rand -hex 32)" ./bin/agentd serve -config config.json
```

环境变量会覆盖配置文件中的同名关键配置：

```text
AGENTD_LISTEN
AGENTD_BIND
AGENTD_PORT
AGENTD_TOKEN
AGENTD_CODEX_BIN
AGENTD_CODEX_ARGS
AGENTD_PROJECTS
AGENTD_SCAN_ROOTS
AGENTD_OUTPUT_BUFFER_BYTES
```

`AGENTD_PROJECTS` 用于精确声明项目目录，多个目录用逗号分隔。`AGENTD_SCAN_ROOTS` 用于扫描工作区，会把根目录和根目录下一层子目录加入项目列表。

### 5. Doctor 排查

```bash
AGENTD_TOKEN=test-token \
AGENTD_SCAN_ROOTS="/Users/gaixiaotongxue/code" \
./bin/agentd doctor
```

服务启动后也可以检查：

```bash
curl -H "Authorization: Bearer $AGENTD_TOKEN" \
  "http://127.0.0.1:8787/api/doctor"
```

### 6. API 示例

健康检查：

```bash
curl http://127.0.0.1:8787/healthz
```

项目列表：

```bash
curl -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://127.0.0.1:8787/api/projects
```

创建 Codex 会话：

```bash
curl -X POST \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"project_id":"code","prompt":"帮我查看这个项目结构","cols":120,"rows":32}' \
  http://127.0.0.1:8787/api/sessions
```

## 风险与优化

当前 MVP 限制：

- 单用户、单 Token。
- session 只存在内存中，重启会丢失；同一个项目下可以显示多个当前进程内会话。
- 每个 session 同时只允许一个 WebSocket 客户端。
- 终端输出只保留最近 128KB。
- 已集成 xterm.js，但终端日志只作为辅助面板，不持久化完整历史。

安全建议：

- 不要监听公网地址。
- 不要使用短 Token。
- Tailscale ACL 尽量限制只有 iPad 能访问 Mac 的 `8787` 端口。
- 不要把 `AGENTD_TOKEN` 放进截图、共享链接或 URL。
- 如果临时使用 `0.0.0.0`，确认只在可信网络中使用。

后续优化：

- 加 `launchd` 后台运行。
- 持久化会话和对话消息。
- 加 session 历史和 diff 视图。
- 加项目级权限模式和高危命令审批。
- 扩展 Claude Code、OpenCode、自定义 shell task。
