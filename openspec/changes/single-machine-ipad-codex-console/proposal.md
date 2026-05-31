## Why

iPad 上远程使用 Codex 的体验不应该依赖每个项目手动启动一个独立服务。当前需要一个单机可运行的常驻控制台，让开发机启动一次后，就能通过 Tailscale 在 iPad Web 中选择项目并启动 Codex 会话。

## What Changes

- 新增一个 Go 实现的 `agentd` 单机服务，内置静态 Web UI。
- 支持 Bearer Token 鉴权，默认只监听本机地址，显式配置后可绑定 Tailscale IP。
- 支持配置项目 allowlist，Web 端只能选择已配置项目，不能传任意路径。
- 支持通过 PTY 启动交互式 Codex CLI 会话，桥接输入、输出、窗口尺寸和停止操作。
- 提供健康检查、就绪检查、doctor API 和命令行 doctor，方便 Tailscale/iPad 排障。
- 提供中文 README，包含构建、启动、Tailscale 访问和安全边界。

## Capabilities

### New Capabilities

- `single-machine-console`: 单机 Web 控制台能力，覆盖配置、鉴权、项目列表、会话启动、实时终端和停止流程。
- `tailscale-access`: Tailscale 访问能力，覆盖绑定地址、Token、doctor 检查和 iPad 访问说明。

### Modified Capabilities

无。

## Impact

- 新增 Go 模块、HTTP/WebSocket 服务、PTY 会话管理和静态前端资源。
- 新增 OpenSpec 规格和任务文档。
- 引入 Go 依赖：`github.com/creack/pty`、`github.com/gorilla/websocket`。
