# 贡献指南

## 目标

欢迎贡献能让 Mimi Remote 更稳定、更安全、更容易安装的改动。优先级是可运行、低维护成本和清晰边界，不追求复杂架构。

## 开发准备

后端检查：

```bash
go mod tidy
go test ./...
go build -o bin/agentd ./cmd/agentd
```

iOS 工程生成：

```bash
cd ios/MimiRemote
xcodegen generate
```

Swift 编译检查：

```bash
xcodebuild \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

## 代码要求

- Go 后端优先保持单机可运行，不引入不必要的中间件。
- SwiftUI 代码优先使用原生控件和清晰状态流，不把 Web/PWA 旧链路加回来。
- 新增核心逻辑需要中文注释说明关键设计原因。
- 涉及安全、鉴权、路径 allowlist、审批策略的改动必须补测试。
- 文档默认使用中文，按“目标、方案、实现、风险与优化”的顺序写。

## 归属和品牌边界

- 不提交从闭源产品复制来的代码、图标、截图、交互细节或宣传文案。
- 参考开源项目时，在 PR 中说明来源、许可证和具体参考范围。
- 不把本项目宣传成任何商业产品的免费替代品。
- 不使用 OpenAI 官方 Logo 或容易造成官方背书误解的视觉元素。
- App Store、README、Release Note 中统一使用 `Mimi Remote` 作为用户侧产品名；`mimi-remote` 作为仓库、Go module 和 formula 名。

## PR 前自查

- 改动范围是否足够小。
- 是否保留现有安全默认值。
- 是否没有泄漏真实 Token、Tailscale IP、私有路径、Apple Team ID 或个人设备名。
- 是否更新了相关 README、隐私政策、发布文档或 API 示例。
- 是否运行了和改动风险匹配的测试。

## 风险与优化

这个项目目前仍按个人/小团队节奏维护。大型重构、复杂插件系统、多用户服务端和公网 SaaS 能力都需要先开 issue 说明真实需求，再逐步推进。
