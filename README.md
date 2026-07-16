# Mimi Remote / mimi-remote

## 目标

Mimi Remote 是一个原生 iPhone / iPad 控制台，用来连接用户自己 Mac 上运行的 `agentd`。仓库、Go module 和后端 formula 统一使用 `mimi-remote`，用户侧产品名统一使用 `Mimi Remote`。

在 Mac 上启动一个单机 `agentd` 控制面，让 iPhone / iPad 原生 App 通过 Tailscale 选择本机项目，并直接使用 Codex app-server JSON-RPC 协议远程运行用户自己的本机开发环境。核心目标是减少“每个项目都要手动启动服务”的重复操作，同时避免 Go 后端长期维护一套自定义 Codex 业务协议。

## 项目边界

- 本项目是独立开发的第三方客户端，不隶属于 OpenAI，也不代表 OpenAI 官方产品。
- 本项目不是任何商业产品的“免费替代品”，也不以复刻其他产品的 UI、交互或宣传语作为目标。
- `Codex`、`OpenAI` 等名称只用于说明兼容的用户自有工具链；项目不会使用官方 Logo 或容易造成混淆的品牌元素。
- 如果后续参考其他开源项目的代码、设计或文案，必须保留许可证和归属说明，并优先做出自己的产品取舍。
- 本项目使用 [MIT License](LICENSE)，第三方归属说明见 [NOTICE.md](NOTICE.md)，完整依赖许可正文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
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
- 未显式选择模型时不发送 `model`，由本机 app-server rollout 决定；远程默认保持 `effort=xhigh`、`approvalPolicy=on-request`、`danger-full-access` sandbox、默认禁网。
- API、control-plane 和 gateway 都需要 Bearer Token。
- 默认不接受 URL query token，避免 token 出现在浏览器历史、日志或 Referer 里。
- MVP 不建议公网暴露，只建议本机或 Tailscale 使用。

已下线旧路径：

- `/api/sessions*` REST、`/api/sessions/{id}/ws` 和内置 Web/PWA 静态站点已经删除。
- iPhone / iPad 原生 App 的核心链路使用 `/api/projects`、`/api/workspaces/resolve`、`/api/directories/list`、`/api/app-server/config` 和 `/api/app-server/ws`；Worktree、Git、文件预览、actions、语音和能力发现使用各自受鉴权的 `/api/*` 控制面接口。
- 浏览器/Safari 入口不再维护；需要远程使用时请安装原生 iPhone / iPad App，并通过 Tailscale 访问 `agentd`。

## 文档索引

- [项目现状与关键决策](docs/project-status.md)：当前架构、能力、历史同步约束和已知风险。
- [P0 / P1 发布推进清单](docs/p0-p1-roadmap.md)：发布门禁、当前完成度和外部准备项。
- [安装、升级与回滚](docs/install-upgrade-rollback.md)：macOS Homebrew、Linux user-systemd、备份和应急回滚。
- [iOS 工程说明](ios/MimiRemote/README.md)：iOS 目录、构建和验收。
- [Tailscale 直连与上海 Peer Relay 运维](docs/tailscale-peer-relay-ops.md)：部署、验证和回滚。
- [Codex Mac App 功能对照](docs/codex-mac-feature-parity.md)：当前能力与后续优先级。
- [与 Litter 的能力对照](docs/litter-comparison.md)：双方优势、缺口和 Mimi Remote 的取舍边界。
- [Codex app-server 协议支持边界](docs/codex-protocol-support.md)：当前放行方法、反向 RPC 和升级检查。
- [生产可达性审计](docs/production-reachability-audit.md)：生产主链路和旧代码边界。
- [隐私政策](docs/privacy-policy.md)：数据处理与网络边界。

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
- 启动 Homebrew 后台服务，并等待带 Bearer Token 的 `/api/readyz` 通过
- 在当前终端输出 iPad 扫码配对二维码

首次运行前需要先安装并登录 Codex CLI；`agentd up` 会复用已有配置，不会重复覆盖已配对的 Token。需要排查环境时运行 `agentd doctor --fix`。

#### Linux Release 包

Linux 不使用 Homebrew。正式 Release 包内含 `scripts/install-linux.sh`，下载归档并校验 `checksums.txt` 后执行：

```bash
bash ./scripts/install-linux.sh install
```

脚本会安装 user-systemd service，升级时保留上一版，并在新服务未就绪时自动恢复。安装后可直接使用 `agentd up/start/restart/stop/status/logs`；CLI 会在 Linux 映射到 `systemctl --user` 和 `journalctl --user`，不需要记两套日常命令。卸载使用已保存的 `install-linux.sh uninstall`，默认完整保留配置与 Token，方便重装后继续使用。完整下载、升级、回滚和卸载命令见 [安装、升级与回滚](docs/install-upgrade-rollback.md)。

历史版本如果只存在 `codex-ipad-agent/config.json`，新版在默认路径启动时会把原始配置安全复制到 `mimi-remote/config.json`，新文件使用 `0600`，旧文件保留作为回退；不会重写 auth、projects、未知字段或移动旧 upstream Token/Worktree 路径。显式 `--config` 和 `AGENTD_CONFIG` 永远不触发自动迁移。

如果 Mac 已安装并登录 Tailscale，`setup` 会优先把 `agentd` 绑定到 Tailscale IP；`serve` 同时增加相同端口的 `127.0.0.1` 监听，供同机 Catalyst 安全直连，不扩大到所有网卡。没有 Tailscale 时仍使用 `127.0.0.1:8787`，并给出真机 iPad 不可直连的警告。

`agentd up`、`agentd start`、`agentd restart` 和后台 `serve` 会在启动服务前检查 `codex.bin`。旧绝对路径失效时，程序会依次检查当前 PATH、ChatGPT App 和 Codex App 内置二进制，并将可执行的绝对路径原子写回配置；这个修复只修改 `codex.bin`，不会轮换 Token 或覆盖项目。随后命令使用当前平台的系统服务管理器后台启动服务：macOS 调用 `brew services start mimi-remote`，Linux Release 调用 `systemctl --user start mimi-remote.service`。命令等待带鉴权的 `/api/readyz` 通过后，才在当前终端输出扫码连接二维码。`agentd serve` 只有在交互式前台终端运行时才会输出二维码；后台 service 不会把 Token 写入服务日志。`agentd up`、`agentd start` 和 `agentd pair` 会输出连接信息：

停止服务统一使用 `agentd stop`；底层排障时，macOS 对应 `brew services stop mimi-remote`，Linux 对应 `systemctl --user stop mimi-remote.service`。`serve` 收到退出信号时会先停止 HTTP 新请求并最多等待 5 秒排空普通请求，再关闭会话和托管 Codex upstream；超时会强制关闭连接。托管 upstream 意外退出时，`agentd` 会主动关闭 HTTP 并以非零状态退出，交给 Homebrew `keep_alive` 或 systemd `Restart=on-failure` 恢复，避免留下端口可用但核心运行时已失效的半健康进程。

```text
Endpoint：http://100.x.x.x:8787
Token：<随机 token>
连接链接：mimiremote://connect?endpoint=...&token=...
配对链接：mimiremote://pair?endpoint=...&issued_at=...&expires_at=...&pair_sig=...
二维码有效期至：<UTC 时间>
```

iPad App 首次启动后优先点“扫描 Mac 上的配对二维码”，扫描二维码会先用短期签名票据向 Mac 兑换 Endpoint/Token，再自动测试连接；测试成功后点击“保存并加载”。每张短期票据在当前 `agentd` 进程内只能成功兑换一次，并发重复兑换会被拒绝；同一秒刷新二维码也会生成独立票据。二维码和配对链接不包含长期 `agentd` Token，也不包含本机 app-server upstream token；手动连接用的 Token 和 `connect` 链接仍作为扫码不可用时的 fallback。二维码已使用、过期，或兑换成功后客户端网络中断时，重新运行 `agentd pair` 刷新；扫码不可用时再展开“高级手动连接”输入 Endpoint/Token。

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

# 重启当前平台后台服务
agentd restart

# 停止当前平台后台服务
agentd stop

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

`agentd status` 会分别显示“进程存活”和“Codex 服务可用”。机器可读输出中的 `process_ok` 只代表 `/healthz` 可达，`service_ok` 必须在带 Token 的 `/api/readyz`、配置检查和真实 app-server WebSocket 握手全部通过后才为 `true`；Linux 安装/升级脚本使用后者作为成功门禁。

`agentd logs -n <行数>` 在 macOS 和 Linux 使用相同边界：正数必须在 1 到 5000 之间，`0` 或负数回落到默认 120 行，超过上限会明确报错；追加 `-f` 只切换为持续跟随，不改变行数校验。

Homebrew service 会执行：

```bash
agentd serve
```

`brew services start mimi-remote` 本身不会把服务 stdout 回传到当前终端，所以想要“后台运行但终端显示二维码”时请用 `agentd start`。为避免 Token 留在后台服务日志里，Homebrew service 模式不会打印二维码。

Homebrew service 固定读取当前平台的默认 `mimi-remote/config.json`。因此 `agentd up`、`agentd start` 和 `agentd restart` 不支持 `--config` 或 `AGENTD_CONFIG` 指向其他路径；命令会在修改 brew 服务状态前直接报错，避免 CLI 检查的是一份配置、launchd 实际启动的却是另一份配置。需要使用自定义配置时走前台模式：

```bash
agentd serve --config /path/to/config.json
```

`agentd serve` 默认读取当前系统的用户配置目录，也可以用 `AGENTD_CONFIG=/path/to/config.json` 覆盖。在 `app_server.transport=ws` 且 `app_server.managed=true` 时，`agentd` 会自动启动并托管本机 loopback `codex app-server`，用户不需要手动再开一个终端。

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

`/api/voice/transcribe` 默认使用 `voice.transcription_provider=openai`：

- 配置 `AGENTD_TRANSCRIPTION_API_KEY` 或 `OPENAI_API_KEY` 后，走公开 OpenAI Speech-to-text API。
- 没有 API Key 时返回明确的配置错误，不会自动读取 `~/.codex/auth.json`。
- 旧配置里的 `auto` 仅作为兼容别名，同样只走公开 API。
- 如需个人实验，可显式设置 `AGENTD_TRANSCRIPTION_PROVIDER=codex`，使用本机 Codex 登录态请求 ChatGPT `/transcribe`；这是非公开接口，可能随 Codex 升级失效，不作为开源发布的稳定能力承诺。Token 只在 Mac 上使用，不会返回给 iPad。

iPad 端录音只上传给自己的 `agentd`，由 Mac 端完成转写，再把文本送进真实对话。

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

Mac Catalyst 会在冷启动时检测同机 `127.0.0.1:8787`，并用当前档案已有 Token 验证后优先本机直连；首次配对仍需二维码或访问码。手动输入本机、局域网或 Tailscale HTTP 地址时，省略端口会按 `agentd` 默认值补为 `8787`。

App 可以保存多台 Mac，但同一时间只连接一台。每台 Mac 的 Token 使用独立 iOS Keychain account 保存，UserDefaults 只保存显示名、Endpoint、最近成功时间和当前档案 ID，不保存 Token；已有档案可在设置中重命名，这个操作只更新本地显示名称，不读取 Token，也不重建当前连接。“忘记当前 Mac”或删除其它档案会先展示目标和重新配对影响，只有二次确认后才删除 Keychain 访问码。iPad App 固定走 `/api/app-server/ws` + app-server JSON-RPC 直连链路。为了支持本机/Tailscale 裸 IP HTTP，App 在系统层声明 `NSAllowsArbitraryLoads`；iOS 27 实测中只声明 `NSAllowsLocalNetworking` 仍会触发 ATS `-1022`。安全边界由应用层在设置提交、REST 请求和 WebSocket 握手前统一校验 Endpoint，只允许本机、局域网、Tailscale、`.ts.net` 或 HTTPS。CI 会防止 ATS 配置再次拦截 Tailscale HTTP，并保留应用层公网 HTTP 拒绝测试。不要把 agentd 暴露到公网。

App 端设计边界：

- SwiftUI 原生实现，不使用 WebView。
- 输入框、会话索引、消息、事件归并、运行日志四块分离。
- direct 模式下 Swift 客户端自己处理 app-server JSON-RPC request/response、notification 和 server request。
- app-server 原始事件在 Swift 端投影为内部 `AgentEvent`，再通过 `EventReducer` 分发给 `MessageStore`/`ConversationStore` 和 `LogStore`。
- 日志有节流和最大缓冲，输入框连续输入不会触发日志刷新；当前会话可导出 ANSI 清洗后的有界 UTF-8 `.log`，文件头不读取 Token、Endpoint 或 Keychain。日志正文仍可能包含用户命令、代码和工具输出，对外分享前必须自行检查。
- iOS 不再解析 PTY 文本生成消息气泡；消息区只消费 app-server 结构化 history/event。
- app-server runtime 不依赖终端尺寸，iOS 不再发送 resize 事件。

### 1.4 iPad-only 远程开发闭环

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

长期不用的 managed Worktree 只支持“先预览、再人工确认”清理，不启用后台自动删除。服务端固定以 30 天为候选阈值，并为每个根项目至少保留最近 3 个；旧 registry、未提交改动、未知 Git 状态、运行中会话、仓库身份不匹配和托管目录外路径都会返回 blocker：

```bash
# 第一步只生成 10 分钟有效的 dry-run 计划，不删除任何文件。
preview="$(curl --fail --silent --show-error \
  -X POST "http://127.0.0.1:8787/api/worktrees/cleanup" \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}')"

printf '%s\n' "$preview" | jq '{policy, candidate_paths, worktrees}'

# 第二步必须回传同一计划的 plan_id 和精确候选路径；执行前还会整体重新评估。
plan_id="$(printf '%s' "$preview" | jq -r '.plan_id')"
path="$(printf '%s' "$preview" | jq -r '.candidate_paths[0]')"
curl --fail --silent --show-error \
  -X POST "http://127.0.0.1:8787/api/worktrees/cleanup" \
  -H "Authorization: Bearer $AGENTD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg plan_id "$plan_id" --arg path "$path" \
    '{dry_run:false,confirm:true,plan_id:$plan_id,paths:[$path]}')"
```

清理执行永远不使用 `git worktree remove --force`，旧 `/api/worktrees/delete` 即使收到 `force=true` 也会直接拒绝。Gateway 在 managed Worktree 上建立 `thread/start`、`thread/resume` 或 `thread/fork` 时会持有 pending-use lease，成功登记 thread、明确失败或连接关闭后才释放，因此普通删除也不能撞上尚未返回的会话创建。如果预检后仍发生外部 Git 竞争，响应会同时返回已经完成的 `deleted_paths` 和 `failed_path/error`；客户端必须刷新列表，不能把部分成功误报为“完全没有执行”。如果 checkout 已删除但 registry 文件 unlink 失败，普通删除会返回 `registry_cleanup_error`，cleanup 仍把路径计入 `deleted_paths`，prune 则在 `failed_paths` 中保留失败详情，便于稍后重试。

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

发布使用 GoReleaser。Release workflow 固定使用已验证的 GoReleaser `v2.15.3`：该版本包含发布日志敏感信息保护修复，同时仍能为当前 `brew services` 方案生成 `Formula/mimi-remote.rb`。`brews` 已被上游标记为 deprecated，后续单独迁移 Cask，不能在首个公开版本前临时改发布格式。仓库 tag 形如 `v0.1.0` 时，GitHub Actions 会：

1. 运行 `go test ./...`
2. 构建 darwin/linux 的 amd64/arm64 `agentd`
3. 创建 GitHub Release 和 checksums
4. 更新 `gaixianggeng/homebrew-tap` 里的 `Formula/mimi-remote.rb`

发布前置条件：

- GitHub 主仓库名称必须为 `gaixianggeng/mimi-remote`，且 Visibility 必须为 **Public**，与 Go module、公开文档和 Formula homepage 保持一致。
- `gaixianggeng/homebrew-tap` 已创建，且 Visibility 必须为 **Public**；只有两个仓库都公开，才能保证用户无需 GitHub 认证即可安装 Homebrew Formula。
- 主仓库已配置 `TAP_DEPLOY_KEY` secret；对应公钥只以可写 Deploy Key 的形式安装在 `homebrew-tap`，不会复用维护者账号的广域 PAT。
- Release workflow、GoReleaser 配置和源码改动已经 commit 并 push；确认后再打 `v*` tag。
- 发布机或 CI 中 `go mod tidy` 不会产生额外 diff。

Release workflow 会通过 GitHub API JSON 先验证主仓库名称、主仓库与 Tap 均为 PUBLIC，再用 Deploy Key 对 Tap 的 `main` 执行无副作用的 dry-run push 验证写权限；任一条件不满足都会在 GoReleaser 发布前停止。门禁不输出私钥或 API JSON 原文；本地可用 `bash ./scripts/check-release-prerequisites.sh --self-test` 验证 PUBLIC / PRIVATE / 损坏 JSON 的判定逻辑，不会访问网络。

发布前本地检查：

```bash
go mod tidy
go test ./...
bash ./scripts/check-public-repo-safety.sh

CGO_ENABLED=0 go build \
  -trimpath \
  -ldflags "-s -w -X main.version=0.0.0-test" \
  -o /tmp/agentd \
  ./cmd/agentd

/tmp/agentd version
```

正式打 tag 前使用仓库唯一的本地发布入口做快照检查：

```bash
bash ./scripts/verify-release.sh
```

脚本会要求当前 `go env GOVERSION` 与 `go.mod` 完全一致，下载并校验官方 GoReleaser `v2.15.3` 预编译包，然后生成四个平台归档、Homebrew Formula 并执行 `check-release-artifacts.sh`。不要改用 `go run ...goreleaser@v2.15.3`：GoReleaser 自身要求更高版本 Go，`go run` 会自动切换工具链，导致最终 `agentd` 可能不是 `go.mod` 声明版本构建。只检查配置、不生成 `dist` 时使用 `bash ./scripts/verify-release.sh check`。

若 GitHub Release 已创建但 Homebrew tap 推送失败，不要改 tag；修复 Token/权限后重跑原 workflow 的失败任务。GoReleaser 会保留既有发布说明并替换同 tag 的同名附件，再继续更新 tap。具体边界和核对项见 [安装、升级与回滚](docs/install-upgrade-rollback.md#github-release-成功tap-更新失败)。

### iOS TestFlight 内测

Mimi TestFlight 不再使用 GitHub Actions。安装通用命令后，使用 `git testflight-push` 代替 `git push`：它先推送 `main`、确认远端 SHA，再在本机自动选择下一个 build、签名归档、上传并分发到 `咪咪 Internal`。

```bash
./scripts/install_git_testflight_push.sh
git testflight-push --what-to-test '验证 iPad 连接、项目、会话、日志和审批链路。'
```

push 失败不会上传，同一 commit 发布成功后默认不会重复生成构建。ASC Key、Distribution P12 和密码只存在本机 `~/.config/ios-testflight/mimi/`。完整配置、dry-run 和恢复方式见 [本地自动发布 Mimi TestFlight](docs/local-testflight.md)。公开二进制、Go/iOS CI 和协议检查仍使用现有 GitHub workflows。

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
- 终端日志只作为辅助面板，不持久化完整历史；可手动导出当前内存缓存窗口用于排障。

安全建议：

- 不要监听公网地址。
- 不要使用短 Token。
- Tailscale ACL 尽量限制只有 iPad 能访问 Mac 的 `8787` 端口。
- 不要把 `AGENTD_TOKEN` 放进截图、共享链接或 URL。
- 如果临时使用 `0.0.0.0`，确认只在可信网络中使用。

后续优化：

- Cloud / projectless thread。
- 后台 push、真正离线时的远端通知和离线状态同步。
- GitHub Review API 级 inline comment 与更完整的 PR 更新。
- 扩展 Claude Code 能力，但继续保持实验通道和更低权限默认值。

## License

本项目使用 MIT License 发布，完整条款见 [LICENSE](LICENSE)。
