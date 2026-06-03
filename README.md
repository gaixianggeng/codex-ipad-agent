# Codex iPad Agent

## 目标

在 Mac 上启动一个单机 `agentd` 控制面，让 iPad 原生 App 通过 Tailscale 选择本机项目，并直接使用 Codex app-server JSON-RPC 协议远程运行 Codex。核心目标是替代“每个项目都要手动启动服务”的体验，同时避免 Go 后端长期维护一套自定义 Codex 业务协议。

## 方案

目标架构：

```text
iPad 原生 App
  |
  | WebSocket + app-server JSON-RPC
  | Authorization: Bearer <AGENTD_TOKEN>
  v
Mac agentd control plane / thin gateway
  |
  +-- 项目 allowlist / health / doctor
  +-- app-server 启动、诊断、Token 入口
  +-- 可选 raw WebSocket gateway，只做鉴权和安全校验
  |
  v
codex app-server
  |
  v
Codex core / 本机凭证 / 项目目录
```

安全边界：

- `agentd` 运行在开发机本地，Codex 凭证不离开开发机。
- iPad 原生 App 从 `agentd` 获取项目 allowlist，只能使用配置中的项目路径。
- direct app-server 请求必须使用远程安全默认值：`approvalPolicy=on-request`、`workspace-write` sandbox、默认禁网。
- API、control-plane 和 gateway 都需要 Bearer Token。
- 默认不接受 URL query token，避免 token 出现在浏览器历史、日志或 Referer 里。
- MVP 不建议公网暴露，只建议本机或 Tailscale 使用。

兼容路径：

- 旧 `/api/sessions*` REST 和 `/api/sessions/{id}/ws` 仍保留，主要服务 Web/PWA 和迁移回退。
- Go 的 `CodexAppServerRuntime` 属于兼容协议转换层；目标主链路不再依赖它。
- Safari/PWA 不能直接裸连 Codex app-server，因为浏览器 WebSocket 不能自定义 `Authorization` header，且浏览器请求会带 `Origin`。浏览器路径继续走 agentd 兼容 API，或后续单独做 HTTPS/WSS 网关。

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

目标体验按 iOS/iPadOS 26 推进，`project.yml` 的 deployment target 为 iOS 26.0。原生 App 的目标主链路是通过 `agentd` 薄网关或受控 endpoint 直接说 Codex app-server JSON-RPC；`agentd` 不再把 Codex 事件翻译成自定义移动端业务协议。

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
- 模式：`兼容模式` 走旧 `/api/sessions*`；`直连模式` 走 `/api/app-server/ws` + app-server JSON-RPC

Token 使用 iOS Keychain 保存，Endpoint 和模式使用 UserDefaults 保存。MVP 为了支持本机/Tailscale HTTP，App 已开启 ATS HTTP 例外；不要把 agentd 暴露到公网。

App 端设计边界：

- SwiftUI 原生实现，不使用 WebView。
- 输入框、会话索引、消息、事件归并、运行日志四块分离。
- direct 模式下 Swift 客户端自己处理 app-server JSON-RPC request/response、notification 和 server request。
- app-server 原始事件在 Swift 端投影为内部 `AgentEvent`，再通过 `EventReducer` 分发给 `MessageStore`/`ConversationStore` 和 `LogStore`。
- 日志有节流和最大缓冲，输入框连续输入不会触发日志刷新。
- 终端 parser 只作为兼容回退，不是主消息来源。
- app-server runtime 不依赖终端尺寸；旧 PTY fallback 仍固定 `120x32`，不跟随键盘或布局变化频繁发送 resize。

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

页面里输入 `AGENTD_TOKEN` 后连接。Web/PWA 当前走兼容 API；原生 iPad App 可以在设置页切换 `兼容模式` 和 `直连模式`。

当前原生 iPad App 默认先使用兼容模式，确保只启动 `agentd` 也能工作。启用 direct 模式前，先按下面的方式启动 loopback `codex app-server` 和 `agentd` gateway，然后在 App 设置页把模式切到 `直连模式`，点击“测试连接”和“保存并加载”。

注意：原生 iPad App 会在 HTTP 和 WebSocket 握手里使用 `Authorization: Bearer <token>`。浏览器 WebSocket 不能设置 Authorization header；如果仍要使用内置 Web/PWA 调试入口，需要显式开启兼容模式：

```bash
export AGENTD_ALLOW_QUERY_TOKEN=1
```

这个模式会把 token 放进 WebSocket URL query，只建议本机或可信 Tailscale 网络内临时使用。

direct app-server gateway 需要本机 loopback WebSocket upstream，不复用兼容 runtime 的 managed stdio 连接。上游 app-server 如果启用 capability token，给 `agentd` 配独立 token file：

```bash
APP_SERVER_TOKEN="$(openssl rand -hex 32)"
printf "%s\n" "$APP_SERVER_TOKEN" > /tmp/codex-app-server-ws-token

codex app-server \
  --listen ws://127.0.0.1:4222 \
  --ws-auth capability-token \
  --ws-token-file /tmp/codex-app-server-ws-token

AGENTD_APP_SERVER_TRANSPORT=ws \
AGENTD_APP_SERVER_LISTEN=ws://127.0.0.1:4222 \
AGENTD_APP_SERVER_WS_TOKEN_FILE=/tmp/codex-app-server-ws-token \
./bin/agentd serve
```

`AGENTD_TOKEN` 只用于 iPad/Web 访问 `agentd`；`AGENTD_APP_SERVER_WS_TOKEN_FILE` 只用于 `agentd` 访问本机 app-server upstream，二者不要复用。

### 2.1 direct / 兼容模式切换

切到 direct 模式：

1. 启动 `codex app-server --listen ws://127.0.0.1:4222`，建议启用 capability token。
2. 用 `AGENTD_APP_SERVER_LISTEN` 和 `AGENTD_APP_SERVER_WS_TOKEN_FILE` 启动 `agentd`。
3. iPad App 设置页选择 `直连模式`。
4. 点击“测试连接”，确认能读取 `/api/app-server/config` 且 gateway 可用。
5. 点击“保存并加载”，会断开旧 WebSocket 并按 direct 模式重新拉取项目和会话。

回滚到兼容模式：

1. iPad App 设置页选择 `兼容模式`。
2. 点击“保存并加载”。
3. 可以停止独立 `codex app-server` upstream；`agentd` 会继续使用旧 `/api/sessions*` 和 `/api/sessions/{id}/ws`。
4. Web/PWA 始终优先使用兼容模式，除非后续单独做浏览器 HTTPS/WSS 网关。

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
AGENTD_ALLOW_QUERY_TOKEN
AGENTD_CODEX_BIN
AGENTD_CODEX_ARGS
AGENTD_RUNTIME
AGENTD_APP_SERVER_TRANSPORT
AGENTD_APP_SERVER_LISTEN
AGENTD_APP_SERVER_MANAGED
AGENTD_APP_SERVER_FALLBACK_PTY
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

兼容 API 创建 Codex 会话：

```bash
curl -X POST \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"project_id":"code","prompt":"帮我查看这个项目结构","cols":120,"rows":32}' \
  http://127.0.0.1:8787/api/sessions
```

## 风险与优化

### 安全与成本控制

- 推荐只通过 Tailscale 暴露 `agentd`，不要开放到公网。
- Tailscale ACL 建议只允许可信 iPad 访问 Mac 的 `8787` 端口。
- Token 使用 32 字节以上随机值，例如 `openssl rand -hex 32`。
- direct 模式下，`agentd` 只做 app-server 启动、鉴权、安全校验和转发，不做业务协议转换。
- direct gateway 到 app-server upstream 使用独立 capability token file，不暴露给 iPad。
- 审批请求默认应 fail closed：超时、断线、未知类型都拒绝。
- 不允许移动端启用 `dangerFullAccess` 或 `approvalPolicy=never`。
- 结构化 runtime 展示 token usage / rate limit，便于控制成本和排查配额。

当前 MVP 限制：

- 单用户、单 Token。
- 兼容模式的 running session 只存在内存中，重启会丢失；direct 模式历史来自 app-server thread store。
- 每个 session 同时只允许一个 WebSocket 客户端。
- 兼容 PTY 终端输出只保留最近 128KB。
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
