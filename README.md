# Mimi Remote / mimi-remote

## 目标

Mimi Remote 是一个原生 iPhone / iPad 控制台，用来连接用户自己 Mac 上运行的 `agentd`。仓库、Go module 和后端 formula 统一使用 `mimi-remote`，用户侧产品名统一使用 `Mimi Remote`。

在 Mac 上启动一个单机 `agentd` 控制面，让 iPhone / iPad 原生 App 通过 Tailscale 选择本机项目，并直接使用 Codex app-server JSON-RPC 协议远程运行用户自己的本机开发环境。核心目标是减少“每个项目都要手动启动服务”的重复操作，同时避免 Go 后端长期维护一套自定义 Codex 业务协议。

## 项目边界

- 本项目是独立开发的第三方客户端，不隶属于 OpenAI，也不代表 OpenAI 官方产品。
- 本项目不是任何商业产品的“免费替代品”，也不以复刻其他产品的 UI、交互或宣传语作为目标。
- `Codex`、`OpenAI` 等名称只用于说明兼容的用户自有工具链；项目不会使用官方 Logo 或容易造成混淆的品牌元素。
- 如果后续参考其他开源项目的代码、设计或文案，必须保留许可证和归属说明，并优先做出自己的产品取舍。
- 本项目使用 [MIT License](LICENSE)，第三方归属说明见 [NOTICE.md](NOTICE.md)。
- 当前个人部署只让 App 访问 Mac 的 Tailscale Endpoint；Tailscale 会自动选择直连、上海 VPS Peer Relay 或官方 DERP。VPS 不再提供 nginx + SSH 反向隧道形式的应用层公网入口，配置和排障命令见 [docs/tailscale-peer-relay-ops.md](docs/tailscale-peer-relay-ops.md)。

## 方案

目标架构：

```text
iPhone / iPad 原生 App
  |
  | WebSocket + app-server JSON-RPC
  | Authorization: Bearer <AGENTD_TOKEN>
  v
Mac Tailscale Endpoint（唯一应用入口）
  |
  | Tailscale 自动选择 direct
  | -> 上海 VPS Peer Relay
  | -> 官方 DERP
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
- iPhone / iPad 原生 App 从 `agentd` 获取项目 allowlist，只能使用配置中的项目路径。
- `browse_roots`（默认用户 Home，不开放 `/`）只扩大“目录浏览 + 打开 workspace”的范围，不参与项目发现；browse workspace 的会话被绑定到打开时的具体目录（canonical 路径），`turn/start` 切到同根下其他目录会被 gateway 拒绝。
- direct app-server 请求必须使用远程默认值：`model=gpt-5.5`、`effort=xhigh`、`approvalPolicy=on-request`、`danger-full-access` sandbox、默认禁网。
- API、control-plane 和 gateway 都需要 Bearer Token。
- 默认不接受 URL query token，避免 token 出现在浏览器历史、日志或 Referer 里。
- MVP 不建议公网暴露，只建议本机或 Tailscale 使用。

已下线旧路径：

- `/api/sessions*` REST、`/api/sessions/{id}/ws` 和内置 Web/PWA 静态站点已经删除。
- iPhone / iPad 原生 App 只通过 `/api/projects`、`/api/workspaces/resolve`、`/api/directories/list`、`/api/app-server/config` 和 `/api/app-server/ws` 工作。
- 浏览器/Safari 入口不再维护；需要远程使用时请安装原生 iPhone / iPad App，并通过 Tailscale 访问 `agentd`。

## 实现

### 1. Homebrew 首次使用

推荐公开发布后让用户只走这一条路径：

```bash
brew update
brew install gaixianggeng/tap/mimi-remote

codex --version
codex app-server --help

agentd up
```

`agentd up` 会完成首次使用的主流程：

- 用户配置，macOS 默认在 `~/Library/Application Support/mimi-remote/config.json`，Linux 默认在 `~/.config/mimi-remote/config.json`
- iPad 访问 `agentd` 的随机 Token
- `agentd` 访问本机 app-server upstream 的独立 capability token file
- 默认项目扫描目录，优先 `~/code`，否则使用执行 `setup` 时所在目录
- 默认目录浏览授权根（`browse_roots`）：用户 Home。iPad 端可以浏览并打开 Home 下任意目录作为工作区（如 `~/finance`）；它不参与项目发现，会话也只绑定打开的那个目录。隐藏目录、`~/Library` 和常见缓存目录不会出现在浏览列表里。要收窄范围用 `agentd setup --force --browse-root <目录>`，或直接编辑配置里的 `browse_roots`
- 默认 loopback app-server upstream：`ws://127.0.0.1:4222`
- 启动 Homebrew 后台服务，并等待 `/healthz` 可用
- 在当前终端输出 iPad 扫码配对二维码

首次运行前需要先安装并登录 Codex CLI；`agentd up` 会复用已有配置，不会重复覆盖已配对的 Token。需要排查环境时运行 `agentd doctor --fix`。

如果 Mac 已安装并登录 Tailscale，`setup` 会优先把 `agentd` 绑定到 Tailscale IP；否则会使用 `127.0.0.1:8787` 并给出真机 iPad 不可直连的警告。

`agentd up` 和 `agentd start` 会调用 `brew services start mimi-remote` 后台启动服务，等待 `/healthz` 可用，然后在当前终端输出扫码连接二维码。`agentd serve` 只有在交互式前台终端运行时才会输出二维码；作为 Homebrew service 后台运行时不会把 Token 写入服务日志。`agentd up`、`agentd start` 和 `agentd pair` 会输出连接信息：

```text
Endpoint：http://100.x.x.x:8787
Token：<随机 token>
连接链接：mimiremote://connect?endpoint=...&token=...
配对链接：mimiremote://pair?endpoint=...&issued_at=...&expires_at=...&pair_sig=...
二维码有效期至：<UTC 时间>
```

iPad App 首次启动后优先点“扫描 Mac 上的配对二维码”，扫描二维码会先用短期签名票据向 Mac 兑换 Endpoint/Token，再自动测试连接；测试成功后点击“保存并加载”。二维码和配对链接不包含长期 `agentd` Token，也不包含本机 app-server upstream token；手动连接用的 Token 和 `connect` 链接仍作为扫码不可用时的 fallback。二维码过期后重新运行 `agentd pair` 刷新；扫码不可用时再展开“高级手动连接”输入 Endpoint/Token。

常用命令：

```bash
# 首次使用：生成配置、启动后台服务、显示扫码二维码
agentd up

# 查看服务、连接和环境状态
agentd status

# 刷新配对二维码
agentd pair

# 自动检查并修复安全的常见问题
agentd doctor --fix

# 查看最近日志
agentd logs

# 重启 Homebrew 后台服务
agentd restart

# 重新生成配置和 token
agentd setup --force

# 指定扫描目录
agentd setup --scan-root "$HOME/code"

# 指定目录浏览授权根（默认用户 Home；收窄 iPad 可浏览/打开范围时改成具体目录）
agentd setup --force --browse-root "$HOME/code"

# 指定监听地址，例如手动绑定 Tailscale IP
agentd setup --listen "$(tailscale ip -4):8787"

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

`brew services start mimi-remote` 本身不会把服务 stdout 回传到当前终端，所以想要“后台运行但终端显示二维码”时请用 `agentd start`。为避免 Token 留在后台服务日志里，Homebrew service 模式不会打印二维码。`agentd serve` 默认读取当前系统的用户配置目录；也可以用 `AGENTD_CONFIG=/path/to/config.json` 覆盖。在 `app_server.transport=ws` 且 `app_server.managed=true` 时，`agentd` 会自动启动并托管本机 loopback `codex app-server`，用户不需要手动再开一个终端。

### Claude Code 实验通道

目标：在同一个 iPad 客户端、同一个项目目录里，同时查看和进入 Codex / Claude Code 会话；Codex 仍是默认通道，Claude v1 默认关闭。

方案：`agentd` 通过外部 `alleycat-claude-bridge` 子进程把 iPad 的 app-server JSON-RPC WebSocket 转成 Claude bridge 的 stdio JSONL。bridge 不并入本仓库，属于可选依赖；launchd/Homebrew service 的 `PATH` 很窄，建议 `claude.bridge_bin` 写绝对路径。

配置示例：

```json
{
  "claude": {
    "enabled": false,
    "bridge_bin": "/opt/homebrew/bin/alleycat-claude-bridge",
    "args": [],
    "max_concurrent_bridges": 3,
    "env": {
      "TERM": "xterm-256color"
    }
  }
}
```

启用后先验证：

```bash
# 检查 bridge 二进制、版本探测和配置
agentd doctor

# 只验证 Claude channel 能否连上并返回模型
go run ./scripts/ipad-ws-probe.go \
  -endpoint http://127.0.0.1:8787 \
  -token "$AGENTD_TOKEN" \
  -cwd "$PWD" \
  -runtime claude \
  -models-only

# 真实发一轮探测消息
go run ./scripts/ipad-ws-probe.go \
  -endpoint http://127.0.0.1:8787 \
  -token "$AGENTD_TOKEN" \
  -cwd "$PWD" \
  -runtime claude
```

实现边界：

- `/api/app-server/config.channels[]` 会暴露 `runtime_id=claude`、`experimental=true`、`lifecycle=per_connection`、bridge 状态和能力声明。
- v1 是每个 WebSocket 一个 bridge 进程；iPad 锁屏、切后台或网络断开会结束 Claude bridge，正在跑的 Claude turn 可能中断。iOS 侧会落到失败/中断状态，用户可以重新发送。
- Claude v1 只声明并放行基础会话、历史、流式输出、审批、文件 diff、模型列表；目标任务、archive、fork、rate limits 不作为 v1 能力。
- `approvalPolicy=never`、`networkAccess=true`、`danger-full-access` 不会写入 Claude bridge；默认 sandbox 会降到 `workspace-write`。
- 关闭方式：把 `claude.enabled` 改回 `false` 并重启 `agentd`。

### 1.1 语音输入

`/api/voice/transcribe` 默认使用 `voice.transcription_provider=auto`：

- 如果配置了 `AGENTD_TRANSCRIPTION_API_KEY` 或 `OPENAI_API_KEY`，走公开 OpenAI Speech-to-text API。
- 如果没有 API Key，走本机 Codex 登录态，读取 `~/.codex/auth.json`，请求 ChatGPT 后端 `/transcribe`。Token 只在 Mac 上使用，不会返回给 iPad。
- 如果想强制使用 Codex 登录态，设置 `AGENTD_TRANSCRIPTION_PROVIDER=codex`。
- 如果想强制使用公开 API，设置 `AGENTD_TRANSCRIPTION_PROVIDER=openai`。

这条默认链路适合个人开发者：先在 Mac 上完成 `codex login`，iPad 端录音上传给自己的 `agentd`，由 Mac 端转写后再把文本送进真实对话。

### 1.2 开发构建

```bash
cd "$HOME/code/mimi-remote"
go build -o bin/agentd ./cmd/agentd
```

### 1.3 构建原生 iOS App

原生 App 工程位于：

```text
ios/MimiRemote
```

目标体验按 iOS/iPadOS 26 推进，`project.yml` 的 deployment target 为 iOS 26.0。原生 App 的目标主链路是通过 `agentd` 薄网关或受控 endpoint 直接说 Codex app-server JSON-RPC；`agentd` 不再把 Codex 事件翻译成自定义移动端业务协议。

先用 XcodeGen 生成 Xcode 工程：

```bash
cd "$HOME/code/mimi-remote/ios/MimiRemote"
xcodegen generate
```

本机命令行可先编译 iPhoneOS target，验证 Swift 代码是否通过：

```bash
xcodebuild \
  -project MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

测试 target 编译：

```bash
xcodebuild \
  -project MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  clean build-for-testing
```

模拟器运行：

```bash
xcodebuild \
  -project MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  clean build
```

如果本机没有这个模拟器，可以先查看可用设备：

```bash
xcodebuild -showdestinations \
  -project MimiRemote.xcodeproj \
  -scheme MimiRemote
```

App 首次启动会进入设置页：

- Endpoint：例如 `http://127.0.0.1:8787` 或 `http://100.x.y.z:8787`
- Token：`AGENTD_TOKEN`

Token 使用 iOS Keychain 保存，Endpoint 使用 UserDefaults 保存。iPad App 固定走 `/api/app-server/ws` + app-server JSON-RPC 直连链路。MVP 为了支持本机/Tailscale HTTP，App 已开启 ATS HTTP 例外；Tailscale 裸 IP 属于 `100.64.0.0/10`，不能用 ATS 域名例外精确覆盖，因此 App 端会先校验 Endpoint 只允许本机、局域网、Tailscale、`.ts.net` 或 HTTPS。不要把 agentd 暴露到公网。

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

默认会构建 `MimiRemote` Debug 包，安装到名为 `iPad Pro` 的真机，并自动启动 App。

常用覆盖参数：

```bash
# 指定设备名
DEVICE_NAME="My iPad" ./scripts/deploy-ipad.sh

# 指定设备 UDID，适合同名设备或设备名不稳定时使用
DEVICE_ID="YOUR_DEVICE_UDID" ./scripts/deploy-ipad.sh

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

App 始终使用这一个 Endpoint，不配置公网备用地址。网络直连失败时，由 Tailscale 在底层自动切换到上海 VPS Peer Relay，再失败则使用官方 DERP；切换过程不改变 App 的 Endpoint。上海 Peer Relay 的部署和运维见 [Tailscale 直连与上海 Peer Relay 运维手册](docs/tailscale-peer-relay-ops.md)。

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
AGENTD_APP_SERVER_WS_TOKEN_FILE
AGENTD_APP_SERVER_MANAGED
AGENTD_PROJECTS
AGENTD_SCAN_ROOTS
AGENTD_BROWSE_ROOTS
AGENTD_WORKTREES_ROOT
AGENTD_DEV_INSECURE
AGENTD_DEBUG_CODEX_HISTORY
AGENTD_OUTPUT_BUFFER_BYTES
```

`AGENTD_PROJECTS` 用于精确声明项目目录，多个目录用逗号分隔。`AGENTD_SCAN_ROOTS` 用于扫描工作区，会把根目录和根目录下一层子目录加入项目列表。

Worktree 创建前可以先读取当前仓库已有分支，iPad 会用它自动填默认 base；接口只读本机 Git refs，不会执行 fetch/pull：

```bash
curl -X POST "http://127.0.0.1:8787/api/worktrees/branches" \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path":"/Users/me/code/my-repo"}'
```

项目级快捷动作通过配置文件里的 `actions` 定义。iPad 只能读取和执行这里声明过的 action，不能临时传入任意 shell：

```json
{
  "actions": [
    {
      "id": "go-test",
      "name": "Go Test",
      "command": "go",
      "args": ["test", "./..."],
      "timeout_seconds": 60
    },
    {
      "id": "git-status",
      "name": "Git Status",
      "command": "git",
      "args": ["status", "--short"],
      "working_dir": ".",
      "timeout_seconds": 10
    },
    {
      "id": "clean-go-cache",
      "name": "Clean Go Cache",
      "command": "go",
      "args": ["clean", "-cache"],
      "timeout_seconds": 30,
      "requires_confirmation": true
    }
  ]
}
```

设计约束：

- `command` 必须是单个可执行文件路径或 PATH 命令名，参数必须放在 `args`。
- `working_dir` 为空时使用当前 iPad 选中的工作区；相对路径相对该工作区，绝对路径也必须落在当前项目、browse root 或 managed worktree 的授权边界内。
- `requires_confirmation: true` 会让 iPad 执行前弹出二次确认，适合清缓存、部署、数据库迁移、删除文件等高风险动作；它是防误触机制，真正安全边界仍是 allowlist + `working_dir` scope。
- 单个 action 最多运行 120 秒，输出会截断，避免移动端误触长时间任务。

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

iPad 设置页里的 Codex history 深度诊断默认关闭。需要临时排查历史映射问题时，再用 `AGENTD_DEBUG_CODEX_HISTORY=true` 启动服务，或在配置文件里设置 `debug.enable_codex_history=true`。

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

目录浏览（供 iPad「打开工作区」选目录和预览文件用；只列允许范围内的一级目录/普通文件，不递归）：

```bash
# path 传空字符串时从第一个 browse root（没配置则第一个 scan root）开始浏览
curl -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "/Users/me"}' \
  http://127.0.0.1:8787/api/directories/list
```

返回示例：

```json
{
  "path": "/Users/me",
  "parent_path": null,
  "entries": [
    {
      "name": "finance",
      "path": "/Users/me/finance",
      "is_dir": true,
      "can_open": true,
      "can_browse": true,
      "can_preview": false
    },
    {
      "name": "report.pdf",
      "path": "/Users/me/report.pdf",
      "is_dir": false,
      "can_open": false,
      "can_browse": false,
      "can_preview": true
    }
  ]
}
```

浏览边界 = 项目 allowlist ∪ `browse_roots`：路径在允许范围外时统一返回 403（不区分“不存在”与“无权限”），指向允许范围外的 symlink 不会出现在列表里。

列出当前工作区可用快捷动作：

```bash
curl -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "/Users/me/code/app"}' \
  http://127.0.0.1:8787/api/actions/list
```

执行一个已配置动作：

```bash
curl -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "/Users/me/code/app", "id": "go-test"}' \
  http://127.0.0.1:8787/api/actions/run
```

只读查看当前工作区可发现的 Skills 和 MCP 配置：

```bash
curl -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": "/Users/me/code/app"}' \
  http://127.0.0.1:8787/api/capabilities/list
```

该接口只读取 `SKILL.md` 元数据和 `.codex/config.toml` 里的 MCP server 摘要，不启动 MCP server，不返回环境变量值。

## 发布

这里的发布指公开仓库内基于 tag 的二进制和 Homebrew 发布。

发布使用 GoReleaser。Release workflow 固定使用已验证的 GoReleaser `v2.9.0`，原因是当前 Homebrew Formula + `brew services` 的发布方式需要稳定生成 `Formula/mimi-remote.rb`。仓库 tag 形如 `v0.1.0` 时，GitHub Actions 会：

1. 运行 `go test ./...`
2. 构建 darwin/linux 的 amd64/arm64 `agentd`
3. 创建 GitHub Release 和 checksums
4. 更新 `gaixianggeng/homebrew-tap` 里的 `Formula/mimi-remote.rb`

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

### iOS TestFlight 内测

`main` 收到 `ios/MimiRemote/**` 改动后，[默认工作流](./.github/workflows/mimi-testflight.yml) 会自动发布新的内部 TestFlight 构建。GitHub 负责触发、排队和日志，标签为 `mimi-testflight` 的仓库专用 self-hosted ARM64 Mac 负责 Xcode 归档、上传和内部组分发，因此日常发布不消耗 GitHub 托管 macOS 分钟。

本机 runner 使用 `/Applications/Xcode-beta.app`、登录钥匙串中的 Distribution 证书、已安装的 Mimi App Store profile，以及只读的 App Store Connect `.p8` 文件。runner 必须以持有这些材料的 macOS 用户运行，并保持联网和唤醒。仓库仍需配置 `IOS_BUNDLE_ID`、`DEVELOPMENT_TEAM`、内部测试组变量，以及 `ASC_KEY_ID`、`ASC_ISSUER_ID`；如果 `.p8` 不在默认位置，再设置 `MIMI_ASC_API_KEY_PATH`。

如果本机不可用，可手动运行 [GitHub 托管应急工作流](./.github/workflows/mimi-testflight-hosted-fallback.yml)。应急入口会消耗 macOS 托管分钟，并继续使用仓库中的证书、profile、App Store Connect Key 等 Secrets。两条工作流共用 `mimi-testflight` 并发组，避免同时上传构建。

## 风险与优化

### 安全与成本控制

- 推荐只通过 Tailscale 暴露 `agentd`，不要开放到公网。
- Tailscale ACL 建议只允许可信 iPad 访问 Mac 的 `8787` 端口。
- Token 使用 32 字节以上随机值，例如 `openssl rand -hex 32`。
- direct 模式下，`agentd` 只做 app-server 启动、鉴权、安全校验和转发，不做业务协议转换。
- direct gateway 到 app-server upstream 使用独立 capability token file，不暴露给 iPad。
- 审批请求默认应 fail closed：超时、断线、未知类型都拒绝。
- Codex 通道默认使用用户批准下的 `dangerFullAccess`；Claude 实验通道默认降到 `workspace-write`。两者都不允许 `approvalPolicy=never`，网络访问默认关闭。
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

## License

本项目使用 MIT License 发布，完整条款见 [LICENSE](LICENSE)。
