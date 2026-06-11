# Mimi Console Notice

## 目标

这个文件说明 Mimi Console / `codex-ipad-agent` 的归属、第三方品牌边界和开源使用方式。

## 项目归属

Mimi Console 是独立开发的第三方客户端。它连接用户自己 Mac 上运行的 `agentd`，再由 `agentd` 连接用户本机的 Codex CLI / app-server 环境。

本项目不隶属于 OpenAI，也没有获得 OpenAI 的赞助、背书或官方授权。`Codex`、`OpenAI` 等名称只用于描述兼容的用户自有工具链。

## 开源许可

本仓库使用 MIT License 发布，完整条款见 [LICENSE](LICENSE)。

MIT 许可允许使用、修改和分发代码，但分发本项目或其重要部分时，需要保留原始版权声明和许可证文本。

## 第三方依赖

本项目依赖的第三方包保留其各自上游许可证。当前直接依赖包括：

Go 依赖：

- `github.com/creack/pty`
- `github.com/gorilla/websocket`
- `github.com/skip2/go-qrcode`

Swift Package Manager 依赖：

- `swift-markdown`
- `swift-cmark`
- `swift-syntax`
- `swift-custom-dump`
- `swift-snapshot-testing`
- `xctest-dynamic-overlay`

运行时外部工具：

- 用户本机自行安装和登录的 Codex CLI / app-server。

本仓库不打包用户的 Codex 凭证，也不托管第三方服务账号。

## 品牌与设计边界

本项目不会把自己宣传为任何商业产品的免费替代品，也不会以复刻其他产品的 UI、交互、图标、截图或文案为目标。

如果你认为本仓库的代码、文档、视觉设计或宣传文案和你的项目过于相似，欢迎通过 GitHub Issue 说明具体文件、截图或链接。我们会优先处理可以明确定位的归属、许可证和混淆风险。
