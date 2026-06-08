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

已下线旧路径：

- `/api/sessions*` REST、`/api/sessions/{id}/ws` 和内置 Web/PWA 静态站点已经删除。
- iPad 原生 App 只通过 `/api/projects`、`/api/app-server/config` 和 `/api/app-server/ws` 工作。
- 浏览器/Safari 入口不再维护；需要远程使用时请安装原生 iPad App，并通过 Tailscale 访问 `agentd`。

## 实现

### 1. Homebrew 首次使用

推荐公开发布后让用户只走这一条路径：

```bash
brew update
brew install gaixianggeng/tap/codex-ipad-agent

codex --version
codex app-server --help

agentd setup
agentd doctor --check-port
agentd start
agentd doctor
```

`agentd setup` 会生成：

- 用户配置，macOS 默认在 `~/Library/Application Support/codex-ipad-agent/config.json`，Linux 默认在 `~/.config/codex-ipad-agent/config.json`
- iPad 访问 `agentd` 的随机 Token
- `agentd` 访问本机 app-server upstream 的独立 capability token file
- 默认项目扫描目录，优先 `~/code`，否则使用执行 `setup` 时所在目录
- 默认 loopback app-server upstream：`ws://127.0.0.1:4222`

`agentd setup` 会打印实际配置文件路径。首次运行前需要先安装并登录 Codex CLI；`agentd doctor --check-port` 会检查 `codex app-server` 是否支持当前需要的 WebSocket 参数。

如果 Mac 已安装并登录 Tailscale，`setup` 会优先把 `agentd` 绑定到 Tailscale IP；否则会使用 `127.0.0.1:8787` 并给出真机 iPad 不可直连的警告。

`agentd start` 会调用 `brew services start codex-ipad-agent` 后台启动服务，等待 `/healthz` 可用，然后在当前终端输出扫码连接二维码。`agentd serve` 只有在交互式前台终端运行时才会输出二维码；作为 Homebrew service 后台运行时不会把 Token 写入服务日志。`agentd setup` 和 `agentd pair` 会输出同一份连接信息：

```text
Endpoint：http://100.x.x.x:8787
Token：<随机 token>
连接链接：mimi://connect?endpoint=...&token=...
配对链接：mimi://pair?endpoint=...&token=...
```

iPad App 首次启动后优先点“扫码连接”，扫描二维码会自动填入 Endpoint/Token 并测试连接；测试成功后点击“保存并加载”。二维码和连接链接只包含 iPad 访问 `agentd` 的外侧 Token，不包含本机 app-server upstream token。扫码不可用时再手动输入 Endpoint/Token。

常用命令：

```bash
# 启动 Homebrew 后台服务，并在当前终端显示扫码二维码
agentd start

# 重新生成配置和 token
agentd setup --force

# 指定扫描目录
agentd setup --scan-root "$HOME/code"

# 指定监听地址，例如手动绑定 Tailscale IP
agentd setup --listen "$(tailscale ip -4):8787"

# 查看配对信息
agentd pair

# 机器可读输出，适合脚本或后续二维码工具
agentd pair --json

# 检查配置、Codex CLI、项目、Tailscale、runtime 和服务端口，通常在启动服务前使用
agentd doctor --check-port

# 服务启动后复查配置和 runtime
agentd doctor
```

Homebrew service 会执行：

```bash
agentd serve
```

`brew services start codex-ipad-agent` 本身不会把服务 stdout 回传到当前终端，所以想要“后台运行但终端显示二维码”时请用 `agentd start`。为避免 Token 留在后台服务日志里，Homebrew service 模式不会打印二维码。`agentd serve` 默认读取当前系统的用户配置目录；也可以用 `AGENTD_CONFIG=/path/to/config.json` 覆盖。在 `app_server.transport=ws` 且 `app_server.managed=true` 时，`agentd` 会自动启动并托管本机 loopback `codex app-server`，用户不需要手动再开一个终端。

### 1.1 开发构建

```bash
cd "$HOME/code/codex-ipad-agent"
go build -o bin/agentd ./cmd/agentd
```

### 1.2 构建原生 iPad App

原生 App 工程位于：

```text
ios/CodexAgentPad
```

目标体验按 iOS/iPadOS 26 推进，`project.yml` 的 deployment target 为 iOS 26.0。原生 App 的目标主链路是通过 `agentd` 薄网关或受控 endpoint 直接说 Codex app-server JSON-RPC；`agentd` 不再把 Codex 事件翻译成自定义移动端业务协议。

先用 XcodeGen 生成 Xcode 工程：

```bash
cd "$HOME/code/codex-ipad-agent/ios/CodexAgentPad"
xcodegen generate
```

本机命令行可先编译 iPhoneOS target，验证 Swift 代码是否通过：

```bash
xcodebuild \
  -project CodexAgentPad.xcodeproj \
  -scheme CodexAgentPad \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

测试 target 编译：

```bash
xcodebuild \
  -project CodexAgentPad.xcodeproj \
  -scheme CodexAgentPad \
  -configuration Debug \
  -sdk iphoneos26.5 \
  CODE_SIGNING_ALLOWED=NO \
  clean build-for-testing
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

Token 使用 iOS Keychain 保存，Endpoint 使用 UserDefaults 保存。iPad App 固定走 `/api/app-server/ws` + app-server JSON-RPC 直连链路。MVP 为了支持本机/Tailscale HTTP，App 已开启 ATS HTTP 例外；不要把 agentd 暴露到公网。

App 端设计边界：

- SwiftUI 原生实现，不使用 WebView。
- 输入框、会话索引、消息、事件归并、运行日志四块分离。
- direct 模式下 Swift 客户端自己处理 app-server JSON-RPC request/response、notification 和 server request。
- app-server 原始事件在 Swift 端投影为内部 `AgentEvent`，再通过 `EventReducer` 分发给 `MessageStore`/`ConversationStore` 和 `LogStore`。
- 日志有节流和最大缓冲，输入框连续输入不会触发日志刷新。
- iOS 不再解析 PTY 文本生成消息气泡；消息区只消费 app-server 结构化 history/event。
- app-server runtime 不依赖终端尺寸，iOS 不再发送 resize 事件。

### 1.3 iPad-only 远程开发闭环

如果只通过 iPad 和 Codex 对话，不要让 Xcode 构建命令触发交互式权限确认。推荐把当前受信项目的 Codex 会话启动为：

```text
filesystem: unrestricted
approval policy: never
network: enabled
```

这个配置只用于本机受信开发会话，也就是“Codex 帮你改这个仓库并调用 Xcode 部署到你自己的 iPad”。不要把它作为 iPad App 暴露给任意项目的默认运行权限。原因很直接：`xcodebuild` 和 `devicectl` 需要访问 `~/Library/Developer/Xcode`、SwiftPM cache、签名证书、CoreDevice 服务和已配对 iPad。沙箱或审批弹窗会打断 iPad-only 的远程反馈循环。

当前项目提供一条无交互部署命令：

```bash
./scripts/deploy-ipad.sh
```

默认会构建 `CodexAgentPad` Debug 包，安装到名为 `iPad Pro` 的真机，并自动启动 App。

常用覆盖参数：

```bash
# 指定设备名
DEVICE_NAME="盖吃饭的iPad" ./scripts/deploy-ipad.sh

# 指定设备 UDID，适合同名设备或设备名不稳定时使用
DEVICE_ID="00008103-000125C00ED3401E" ./scripts/deploy-ipad.sh

# 指定 Apple Developer Team
IOS_DEVELOPMENT_TEAM="YOUR_TEAM_ID" ./scripts/deploy-ipad.sh

# 只安装不启动
SKIP_LAUNCH=1 ./scripts/deploy-ipad.sh
```

这个脚本是后续“你测试 -> 告诉我问题 -> 我改代码 -> 我重新打到 iPad”的默认执行入口。

### 2. 本机启动

推荐用环境变量启动，避免把真实 Token 写进配置文件：

```bash
export AGENTD_TOKEN="$(openssl rand -hex 32)"
export AGENTD_SCAN_ROOTS="$HOME/code"

./bin/agentd serve
```

本机只提供 API 和 app-server gateway，不再提供 Web/PWA 页面。可用 curl 检查服务：

```bash
curl http://127.0.0.1:8787/healthz
```

原生 iPad App 固定走 direct app-server 链路。设置页优先扫码连接；二维码不可用时再填写 `agentd` Endpoint 和 `AGENTD_TOKEN`。

使用 `agentd setup` 生成的配置时，`agentd serve` 会自动托管 loopback `codex app-server`，原生 iPad App 只需要连接 `agentd`。手动环境变量启动主要用于开发和调试。

注意：原生 iPad App 会在 HTTP 和 WebSocket 握手里使用 `Authorization: Bearer <token>`。不要把 `AGENTD_TOKEN` 放进 URL query。

如果你想手动管理 app-server upstream，可以显式启动 loopback WebSocket。上游 app-server 如果启用 capability token，给 `agentd` 配独立 token file：

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
AGENTD_APP_SERVER_MANAGED=false \
./bin/agentd serve
```

`AGENTD_TOKEN` 只用于 iPad 访问 `agentd`；`AGENTD_APP_SERVER_WS_TOKEN_FILE` 只用于 `agentd` 访问本机 app-server upstream，二者不要复用。

### 2.1 iPad direct 启动

iPad direct 模式启动步骤：

1. 推荐先运行 `agentd setup`，让 `agentd` 自动生成 token file 和托管 loopback app-server。
2. 用 `agentd start` 启动 Homebrew 后台服务并显示二维码；源码调试时用 `agentd serve` 前台启动。
3. iPad App 设置页点击“扫码连接”，扫描终端二维码并自动测试连接。
4. 如果扫码不可用，手动输入 Endpoint 和 Token 后点击“测试连接”，确认能读取 `/api/app-server/config` 且 gateway 可用。
5. 点击“保存并加载”，会断开现有 WebSocket 并按 direct 模式重新拉取项目和会话。

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
export AGENTD_SCAN_ROOTS="$HOME/code"

AGENTD_BIND="$MAC_TS_IP" \
AGENTD_PORT=8787 \
./bin/agentd serve
```

iPad App 设置页填写 Endpoint：

```text
http://<Mac 的 Tailscale IP>:8787
```

如果使用 MagicDNS，也可以打开：

```text
http://<mac-hostname>.<tailnet-name>.ts.net:8787
```

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
AGENTD_APP_SERVER_TRANSPORT
AGENTD_APP_SERVER_LISTEN
AGENTD_APP_SERVER_MANAGED
AGENTD_PROJECTS
AGENTD_SCAN_ROOTS
AGENTD_OUTPUT_BUFFER_BYTES
```

`AGENTD_PROJECTS` 用于精确声明项目目录，多个目录用逗号分隔。`AGENTD_SCAN_ROOTS` 用于扫描工作区，会把根目录和根目录下一层子目录加入项目列表。

### 5. Doctor 排查

```bash
AGENTD_TOKEN=test-token \
AGENTD_SCAN_ROOTS="$HOME/code" \
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

读取 app-server gateway 配置：

```bash
curl -H "Authorization: Bearer $AGENTD_TOKEN" \
  http://127.0.0.1:8787/api/app-server/config
```

## 发布

发布使用 GoReleaser。Release workflow 固定使用已验证的 GoReleaser `v2.9.0`，原因是当前 Homebrew Formula + `brew services` 的发布方式需要稳定生成 `Formula/codex-ipad-agent.rb`。仓库 tag 形如 `v0.1.0` 时，GitHub Actions 会：

1. 运行 `go test ./...`
2. 构建 darwin/linux 的 amd64/arm64 `agentd`
3. 创建 GitHub Release 和 checksums
4. 更新 `gaixianggeng/homebrew-tap` 里的 `Formula/codex-ipad-agent.rb`

发布前置条件：

- `gaixianggeng/homebrew-tap` 仓库已创建，且公开或至少对目标用户可访问。
- 主仓库已配置 `TAP_GITHUB_TOKEN` secret，token 对 `homebrew-tap` 有 `contents:write` 权限。
- Release workflow、GoReleaser 配置和源码改动已经 commit 并 push；确认后再打 `v*` tag。
- 发布机或 CI 中 `go mod tidy` 不会产生额外 diff。

发布前本地检查：

```bash
go mod tidy
go test ./...

CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags "-s -w -X main.version=0.0.0-test" \
  -o /tmp/agentd \
  ./cmd/agentd

/tmp/agentd version
```

如果本机安装了 GoReleaser，可以先做快照检查：

```bash
go run github.com/goreleaser/goreleaser/v2@v2.9.0 check
go run github.com/goreleaser/goreleaser/v2@v2.9.0 release --snapshot --clean --skip=publish
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
- running/history 状态来自 app-server thread store。
- 每个 session 同时只允许一个 WebSocket 客户端。
- 终端日志只作为辅助面板，不持久化完整历史。

安全建议：

- 不要监听公网地址。
- 不要使用短 Token。
- Tailscale ACL 尽量限制只有 iPad 能访问 Mac 的 `8787` 端口。
- 不要把 `AGENTD_TOKEN` 放进截图、共享链接或 URL。
- 如果临时使用 `0.0.0.0`，确认只在可信网络中使用。

后续优化：

- 多 Mac 配置。
- 持久化会话和对话消息。
- 加 session 历史和 diff 视图。
- 加项目级权限模式和高危命令审批。
- 扩展 Claude Code、OpenCode、自定义 shell task。
