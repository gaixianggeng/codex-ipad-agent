# 贡献指南

感谢你愿意改进 Mimi Remote。这个项目优先接受能解决真实使用问题、保持本地优先安全边界、且不会显著增加小团队维护成本的改动。

## 提交 Issue

Bug 请尽量包含：

- iPhone / iPad 型号与系统版本；
- Mimi Remote、`agentd`、Codex CLI 或 Claude bridge 的版本；
- 最小复现步骤、预期结果和实际结果；
- 已脱敏的日志或截图。

不要公开提交 Token、Tailscale IP、私有仓库内容、真实工作目录或完整会话。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 提交 Pull Request

1. 先确认改动范围清晰；较大功能建议先开 Issue 讨论边界。
2. 保留现有架构与安全策略，不引入无必要的云服务、遥测或重型依赖。
3. 核心逻辑添加中文注释，说明为什么这样实现。
4. PR 描述中写清目标、实现、验证结果和已知风险。

## 本地验证

Go 后端改动至少运行：

```bash
go test ./... -count=1
go vet ./...
bash ./scripts/check-codex-protocol.sh
```

iOS 改动至少生成工程并完成无签名构建：

```bash
xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote

bash ./scripts/ios-dev.sh build-for-testing
```

日常 `build` / `run` 优先使用 available、paired、USB 连接的真机，没有可用真机时回退到 `iPad Pro 13-inch (M5)` Simulator。`build-for-testing`、`test` 与 CI 固定使用 Simulator；兼容性测试通过 `IOS_TARGET_MODE=simulator` 和 `IOS_SIMULATOR_NAME` 显式切换。

Claude bridge 改动至少运行：

```bash
cargo fmt --all -- --check
cargo test --locked \
  -p alleycat-codex-proto \
  -p alleycat-bridge-core \
  -p alleycat-claude-bridge
```

公开仓库安全相关改动还应运行：

```bash
bash ./scripts/check-public-repo-safety.sh
bash ./scripts/check-third-party-notices.sh
bash ./scripts/check-ios-privacy-manifest.sh
```
