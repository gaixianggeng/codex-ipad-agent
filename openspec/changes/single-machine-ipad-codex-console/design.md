## Context

本项目是一个单机 MVP：开发机启动一个常驻 `agentd` 服务，iPad 通过 Tailscale 访问 Web UI，并远程启动本机 Codex CLI。用户的主要痛点是每个项目都要手动启动独立服务，因此第一版必须把“项目”降级为配置，把“会话”作为临时子进程。

约束：

- 默认面向个人开发者和可信设备，不做多租户。
- 服务端运行在能访问代码和 Codex 凭证的开发机上。
- iPad 只能通过 Web UI 触发 allowlist 内的项目。
- MVP 要可运行、低维护，避免数据库、队列和复杂前端构建链路。

## Goals / Non-Goals

**Goals:**

- 一个 Go 二进制启动 HTTP 服务和 Web UI。
- 通过 Token 鉴权保护 API 和 WebSocket。
- 通过配置声明项目 allowlist。
- Web UI 能选择项目、创建 Codex 会话、实时查看输出、发送输入、停止会话。
- 支持 Tailscale IP 绑定、health/ready/doctor 检查和中文文档。

**Non-Goals:**

- 不做公网 relay。
- 不做多用户、OAuth、RBAC。
- 不保存历史会话和终端输出。
- 不做完整 IDE、文件树、Monaco 编辑器。
- 不实现 Codex 内部权限系统，首版依赖 Codex CLI 自身和本机用户权限。

## Decisions

1. **单 Go 进程内嵌 Web UI**

   选择 Go `net/http` + `embed` 托管静态资源，避免独立 Node 前端服务。替代方案是 Next.js + Go API，但首版部署复杂度更高。

2. **PTY 启动 Codex**

   使用 `github.com/creack/pty` 启动 `codex --no-alt-screen`，保留交互式输入输出能力。替代方案是 `codex exec`，但它更适合非交互任务，不能自然承接后续输入和审批。

3. **WebSocket 桥接终端**

   使用 `github.com/gorilla/websocket`，每个 session 暂时只允许一个 WebSocket 客户端附着，降低并发和输出回放复杂度。

4. **配置文件优先，环境变量覆盖**

   使用 `config.json` 声明监听地址、Token、Codex 命令和项目列表。环境变量用于快速覆盖部署参数，例如 Tailscale IP 和 Token。

5. **项目 allowlist 是安全边界**

   API 只接受 `project_id`，不接受任意路径。启动时对项目路径做绝对路径、真实路径和目录校验，避免 Web 端逃逸到未授权目录。

6. **首版不持久化 session**

   会话状态保存在内存中，进程重启后丢失。这样能减少数据库依赖，先验证远程调用体验。

## Risks / Trade-offs

- [Risk] Token 泄漏后等同远程控制 Codex → 使用长随机 Token、默认不监听公网、README 明确 Tailscale ACL 建议。
- [Risk] iPad 浏览器刷新导致输出丢失 → 首版保留最近 128KB 输出缓冲，重新连接后回放。
- [Risk] Codex TUI ANSI 输出在普通 DOM 中不完美 → 首版使用 `--no-alt-screen` 降低复杂度，后续可引入 xterm.js。
- [Risk] 子进程残留 → 启动时设置进程组，停止时先 SIGTERM 再 SIGKILL。
- [Risk] Tailscale 网络内其他设备访问 → Token 必填，并建议绑定 Tailscale IP 或配置 ACL。

## Migration Plan

首版为新项目，无历史迁移。回滚方式是停止 `agentd` 进程并删除项目目录。后续如果引入数据库，需要提供从内存状态到 SQLite/MySQL 的兼容迁移。
